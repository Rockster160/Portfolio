require "rails_helper"

# schedule_reminder is now an AUTO tool: no confirmation checkbox, it runs on
# the spot and drops an activity-receipt chip.
RSpec.describe "schedule_reminder auto-run" do
  let(:user)  { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }
  let(:msg)   { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  it "creates the reminder + a receipt chip, and NO checklist" do
    at = 2.hours.from_now.in_time_zone(user.timezone).iso8601
    markers = [{ tool_name: :schedule_reminder, payload: { text: "check the oven", at: at }, span: [0, 0] }]

    result = nil
    expect {
      result = Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
    }.to change { BuddyReminder.where(user: user).count }.by(1)

    expect(result[:action]).to be_nil          # no confirmation checklist
    expect(result[:auto_ran]).to be(true)

    chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
    expect(chip).to be_present
    expect(chip.body).to match(/\A(Byte|Moss) will send you a reminder /)
  end

  # Prod: "please alert me of both of those items" produced second copies of two
  # reminders set three hours earlier, and both fired twice - 3:15 and 3:35, a
  # minute apart each. Buddy had `upcoming_reminders` and never read it, which
  # is why this can't be prompt guidance alone.
  describe "one that's already set" do
    let(:at) { 2.hours.from_now.in_time_zone(user.timezone) }
    let(:ctx) { Buddy::ToolContext.new(user, conversation: convo) }
    let(:tool) { Buddy::Tools[:schedule_reminder] }

    def existing!(text, when_at=at)
      BuddyReminder.create!(user: user, byte_conversation: convo, body: text, fire_at: when_at)
    end

    it "refuses a second copy of the same thing at the same minute" do
      existing!("Write Doug's card")

      expect { tool[:confirm].call({ text: "Write Doug's card", at: at.iso8601 }, ctx) }
        .to raise_error(/already set/i)
    end

    # The two didn't share a single word of phrasing, but they were the same
    # nudge, and Eve got both of them at 3:35.
    it "catches a reworded copy that still means the same thing" do
      existing!("Get your outfit and accessories sorted before your shower.")

      expect { tool[:confirm].call({ text: "Pick out your outfit", at: at.iso8601 }, ctx) }
        .to raise_error(/already set/i)
    end

    it "lets two genuinely different reminders share a minute" do
      existing!("Take the meatloaf out")

      expect { tool[:confirm].call({ text: "Call mom", at: at.iso8601 }, ctx) }.not_to raise_error
    end

    it "lets the same thing be set again at a different time" do
      existing!("Write Doug's card", at - 1.hour)

      expect { tool[:confirm].call({ text: "Write Doug's card", at: at.iso8601 }, ctx) }.not_to raise_error
    end

    it "ignores one that's already been cancelled or fired" do
      existing!("Write Doug's card").update!(cancelled_at: Time.current)

      expect { tool[:confirm].call({ text: "Write Doug's card", at: at.iso8601 }, ctx) }.not_to raise_error
    end

    # A daily 9am and a one-off tomorrow at 9am are different requests, and the
    # recurring one is never "already set" for a particular day.
    it "doesn't compare against a recurring reminder" do
      BuddyReminder.create!(
        user: user, byte_conversation: convo, body: "Write Doug's card",
        fire_at: at, recurrence: { "kind" => "daily", "at" => at.strftime("%H:%M") }
      )

      expect { tool[:confirm].call({ text: "Write Doug's card", at: at.iso8601 }, ctx) }.not_to raise_error
    end
  end

  describe "friendly_future phrasing" do
    let(:ctx) { Buddy::ToolContext.new(user) }
    let(:noon) { Time.current.in_time_zone(user.timezone).change(hour: 18, min: 1) }

    it "gives a bare time for today" do
      expect(ctx.friendly_future(noon)).to eq("at 6:01pm")
    end

    it "prefixes tomorrow / weekday for later days" do
      expect(ctx.friendly_future(noon + 1.day)).to start_with("tomorrow at ")
      expect(ctx.friendly_future(noon + 3.days)).to match(/\Athis \w+ at /)
    end

    it "drops :00 on the hour" do
      on_hour = Time.current.in_time_zone(user.timezone).change(hour: 18, min: 0)
      expect(ctx.friendly_future(on_hour)).to eq("at 6pm")
    end
  end
end
