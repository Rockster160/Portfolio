require "rails_helper"

# Which Buddy thread is THE one — where the morning briefing, a reminder firing,
# a watch tripping and a relay from the other person all land.
#
# Not "most recently active", which follows the person around: a choice made
# once, in the conversation menu, and nothing but making it again moves it.
RSpec.describe "Buddy primary conversation" do
  let(:user) { create(:user) }

  # Deliberately created oldest-first and then touched newest-first, because
  # that is the shape the old rule got wrong.
  let!(:first)  { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: 3.hours.ago) }
  let!(:second) { user.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: 1.minute.ago) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  describe "the default" do
    # Id order rather than activity, so it can't drift.
    it "is the FIRST buddy thread, however busy or quiet the others get", :aggregate_failures do
      expect(ByteConversation.primary_for(user)).to eq(first)
      expect(ByteConversation.for_self_initiated(user)).to eq(first)

      second.touch_activity(Time.current)
      first.update!(last_message_at: 3.weeks.ago)
      expect(ByteConversation.primary_for(user)).to eq(first)
    end

    it "skips a wall tablet, an eval thread, or an archived one", :aggregate_failures do
      [{ metadata: { "kiosk" => true } }, { metadata: { "eval" => "true" } }, { archived: true }].each do |attrs|
        first.update!(metadata: {}, archived: false)
        first.update!(attrs)

        expect(ByteConversation.primary_for(user)).to eq(second), attrs.inspect
      end
    end

    it "is nobody's when they have no buddy threads at all" do
      user.byte_conversations.destroy_all

      expect(ByteConversation.primary_for(user)).to be_nil
    end
  end

  describe "choosing one" do
    it "makes that thread the one everything self-initiated lands in, exclusively and idempotently", :aggregate_failures do
      second.update!(metadata: { "cwd" => "/tmp" })

      ByteConversation.pin_primary!(second)
      ByteConversation.pin_primary!(second)
      first.touch_activity(Time.current)

      expect(ByteConversation.primary_for(user)).to eq(second)
      expect(ByteConversation.for_self_initiated(user)).to eq(second)
      expect(user.byte_conversations.primary.to_a).to eq([second])
      expect(second.reload.metadata).to eq("cwd" => "/tmp")
      expect(second.primary_at).to be_within(5.seconds).of(Time.current)

      # Two marked would make where a briefing lands depend on row order.
      ByteConversation.pin_primary!(first)
      expect(user.byte_conversations.primary.to_a).to eq([first])
    end

    # `update_conversation` merges client-supplied metadata onto the row, so the
    # invariant is a column with a partial unique index rather than a key in
    # that bag.
    it "refuses a second primary at the database level" do
      ByteConversation.pin_primary!(second)

      expect { first.update!(primary_at: Time.current) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "lets each person have their own, without touching anybody else's", :aggregate_failures do
      theirs = create(:user).byte_conversations.create!(mode: :buddy, name: "Suki")
      ByteConversation.pin_primary!(theirs)

      expect { ByteConversation.pin_primary!(second) }.not_to raise_error
      expect(theirs.reload).to be_primary
    end

    # The choice degrades into the rule it replaced instead of leaving
    # briefings homeless.
    it "falls back to the first thread when the chosen one is archived" do
      ByteConversation.pin_primary!(second)
      second.update!(archived: true)

      expect(ByteConversation.primary_for(user)).to eq(first)
    end
  end

  describe "what rides on it" do
    before { ByteConversation.pin_primary!(second) }

    # Asked from inside the first thread, and it still points at the primary:
    # a reminder is about weeks from now, not about which window is open.
    it "is where a scheduled reminder fires and a scheduled trigger announces a skip", :aggregate_failures do
      ctx  = Buddy::ToolContext.new(user, conversation: first)
      tool = Buddy::Tools[:schedule_reminder]
      args = { text: "Water the plants", at: 2.hours.from_now.iso8601 }
      result = tool[:execute].call(args.merge(tool[:confirm].call(args, ctx)[:resolved]), ctx)

      expect(BuddyReminder.find(result[:reminder_id]).byte_conversation).to eq(second)

      trigger = ScheduledTrigger.create!(
        user_id: user.id, trigger: "villager", execute_at: 1.minute.from_now, data: {},
      )

      expect(trigger.buddy_conversation).to eq(second)
    end
  end

  # The first thread claims the flag on creation; a row that predates that
  # still resolves through `primary_among`, which is why the resolved id
  # travels separately from the per-row flag.
  it "carries the explicit flag on the wire, claimed by the first thread on creation", :aggregate_failures do
    expect(first.reload).to be_primary
    expect(second.reload).not_to be_primary

    ByteConversation.pin_primary!(second)
    expect(second.reload.as_wire[:primary]).to be(true)
    expect(first.reload.as_wire[:primary]).to be(false)

    user.byte_conversations.update_all(primary_at: nil)
    expect(ByteConversation.primary_for(user)).to eq(first)
    expect(first.reload.as_wire[:primary]).to be(false)
  end

  describe "how often it asks the database" do
    # No gem for this — one subscriber, and it keeps the numbers below honest
    # rather than aspirational. CACHE/SCHEMA rows aren't round trips.
    def queries(&block)
      found = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload|
        found << payload[:sql] unless payload[:name].in?(["CACHE", "SCHEMA"])
      }
      block.call
      found
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # The conversations index runs on every open, refresh and reconnect. It
    # already has the whole list; going back for the primary is a round trip for
    # data sitting on the page.
    it "answers from rows already in hand without touching the database" do
      convos = user.byte_conversations.active.ordered.to_a

      expect(queries { ByteConversation.primary_among(convos) }).to be_empty
    end

    # Both branches, one query — `ordered` is what makes the fallback free,
    # since it's just the first row of a list already fetched.
    it "takes a single query when nothing is loaded, on the fallback path too", :aggregate_failures do
      expect(queries { ByteConversation.for_self_initiated(user) }.length).to eq(1)

      user.byte_conversations.update_all(primary_at: nil)
      first.update!(metadata: { "kiosk" => true })
      second.update!(metadata: { "kiosk" => true })

      expect(queries { ByteConversation.for_self_initiated(user) }.length).to eq(1)
    end
  end
end
