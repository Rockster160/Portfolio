require "rails_helper"

# When the daily audit goes.
#
# It used to be a flat 6am, which put the report an hour or two ahead of the
# briefing it reads best under. It now hangs off the briefing turn FINISHING -
# the reply is written, it's on screen, and nothing else is going to happen to
# it - so there is no clock to keep in step and nothing polling for it.
RSpec.describe "Daily audit trigger" do
  let(:user)   { User.me }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before { allow(DailyAuditWorker).to receive(:perform_async) }

  def seed!(source:)
    convo.byte_messages.create!(
      user: user, direction: :outbound, state: :pending, body: "brief me",
      metadata: { "kind" => "buddy_trigger", "hidden" => true, "source" => source }
    )
  end

  # The turn's own hook, driven the way finalize_success drives it.
  def finish_turn_on(seed, as: user)
    turn = Buddy::GPT::Turn.allocate
    turn.instance_variable_set(:@user, as)
    turn.instance_variable_set(:@inbound, seed)
    turn.send(:queue_daily_audit)
  end

  it "queues the audit when the scheduled briefing finishes" do
    finish_turn_on(seed!(source: "today_scheduled"))

    expect(DailyAuditWorker).to have_received(:perform_async)
  end

  # A tap on the hero chip is not the morning broadcast. Someone asking for a
  # Today at four in the afternoon shouldn't drag a report along with it.
  it "ignores a Today the person asked for by hand" do
    finish_turn_on(seed!(source: "quick_action"))

    expect(DailyAuditWorker).not_to have_received(:perform_async)
  end

  it "ignores an ordinary reply" do
    plain = convo.byte_messages.create!(
      user: user, direction: :outbound, state: :delivered, body: "hey", metadata: {},
    )
    finish_turn_on(plain)

    expect(DailyAuditWorker).not_to have_received(:perform_async)
  end

  # The audit reads Rocco's traffic and posts into Rocco's thread. Another
  # household member's morning briefing is not a reason to run it.
  it "only fires for the account the audit is about" do
    finish_turn_on(seed!(source: "today_scheduled"), as: create(:user))

    expect(DailyAuditWorker).not_to have_received(:perform_async)
  end

  # A day with no report is a day nobody looks at, and the absence reads as
  # "nothing went wrong" rather than as a gap.
  describe "the backstop" do
    let(:schedule) { Rails.root.join("config/initializers/sidekiq_cron.rb").read }

    it "is one run a day, not a sweep" do
      expect(schedule).to include(%(daily_10am = "0 10 * * * MST"))
      expect(schedule).to include("DailyAuditWorker")
      expect(schedule).to include("cron:  daily_10am")
    end

    it "leaves no polling entry behind" do
      expect(schedule).not_to include("daily_6am")
      audit_block = schedule[/Daily Byte Audit Backstop.*?\}/m]
      expect(audit_block).not_to include("every_5_minutes")
      expect(audit_block).not_to include("every_minute")
    end
  end
end
