require "rails_helper"

# Which Buddy thread is THE one — where the morning briefing, a reminder firing,
# a watch tripping and a relay from the other person all land.
#
# It used to be "most recently active", which was never the right answer, only
# the easy one. That follows the person around: reading a shared thread, tapping
# a routine, or an automation posting its own receipt all move it, so where
# tomorrow's briefing turns up depends on what you did last night. This is a
# choice made once, in the conversation menu, and nothing but making it again
# moves it.
RSpec.describe "Buddy primary conversation" do
  let(:user) { create(:user) }

  # Deliberately created oldest-first and then touched newest-first, because
  # that is the shape the old rule got wrong.
  let!(:first)  { user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: 3.hours.ago) }
  let!(:second) { user.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: 1.minute.ago) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  describe "the default" do
    it "is the FIRST buddy thread, not the busiest" do
      expect(ByteConversation.primary_for(user)).to eq(first)
    end

    it "is where an unasked-for message goes" do
      expect(ByteConversation.for_self_initiated(user)).to eq(first)
    end

    # The whole reason the default is id order rather than activity: it can't
    # drift. Somebody who never opens the setting gets the same thread forever.
    it "doesn't move when another thread becomes the liveliest" do
      second.touch_activity(Time.current)

      expect(ByteConversation.primary_for(user)).to eq(first)
    end

    it "doesn't move when the first thread goes quiet for weeks" do
      first.update!(last_message_at: 3.weeks.ago)

      expect(ByteConversation.primary_for(user)).to eq(first)
    end

    it "skips the wall tablet, which is a screen in a room rather than a person" do
      first.update!(metadata: { "kiosk" => true })

      expect(ByteConversation.primary_for(user)).to eq(second)
    end

    it "skips an eval thread" do
      first.update!(metadata: { "eval" => "true" })

      expect(ByteConversation.primary_for(user)).to eq(second)
    end

    it "skips an archived one" do
      first.update!(archived: true)

      expect(ByteConversation.primary_for(user)).to eq(second)
    end

    it "is nobody's when they have no buddy threads at all" do
      user.byte_conversations.destroy_all

      expect(ByteConversation.primary_for(user)).to be_nil
    end
  end

  describe "choosing one" do
    it "makes that thread the one everything self-initiated lands in" do
      ByteConversation.pin_primary!(second)

      expect(ByteConversation.primary_for(user)).to eq(second)
      expect(ByteConversation.for_self_initiated(user)).to eq(second)
    end

    it "survives the first thread being the liveliest again" do
      ByteConversation.pin_primary!(second)
      first.touch_activity(Time.current)

      expect(ByteConversation.primary_for(user)).to eq(second)
    end

    # Exclusive by construction. Two marked would make where a briefing lands
    # depend on row order, which is the thing this replaced.
    it "takes it off the previous one rather than leaving two marked" do
      ByteConversation.pin_primary!(second)
      ByteConversation.pin_primary!(first)

      expect(user.byte_conversations.primary.to_a).to eq([first])
      expect(ByteConversation.primary_for(user)).to eq(first)
    end

    it "is idempotent" do
      ByteConversation.pin_primary!(second)
      ByteConversation.pin_primary!(second)

      expect(user.byte_conversations.primary.count).to eq(1)
    end

    it "leaves the thread's metadata alone entirely" do
      second.update!(metadata: { "cwd" => "/tmp" })

      ByteConversation.pin_primary!(second)

      expect(second.reload.metadata).to eq("cwd" => "/tmp")
      expect(second).to be_primary
    end

    it "records when it was chosen" do
      ByteConversation.pin_primary!(second)

      expect(second.reload.primary_at).to be_within(5.seconds).of(Time.current)
    end

    # The reason this is a column. `update_conversation` merges client-supplied
    # metadata straight onto the row, so an invariant kept in that bag could be
    # violated by an ordinary PATCH — three threads marked at once, and where a
    # briefing lands back to depending on row order. The partial unique index
    # makes it impossible in the database rather than only in pin_primary!.
    it "refuses a second primary at the database level" do
      ByteConversation.pin_primary!(second)

      expect { first.update!(primary_at: Time.current) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "still lets two different people each have one" do
      other  = create(:user)
      theirs = other.byte_conversations.create!(mode: :buddy, name: "Suki")

      ByteConversation.pin_primary!(second)

      expect { ByteConversation.pin_primary!(theirs) }.not_to raise_error
    end

    it "doesn't touch anybody else's threads" do
      other = create(:user)
      theirs = other.byte_conversations.create!(mode: :buddy, name: "Suki")
      ByteConversation.pin_primary!(theirs)

      ByteConversation.pin_primary!(second)

      expect(theirs.reload).to be_primary
    end

    # Falls back to the default rather than to nothing, so the choice degrades
    # into the rule it replaced instead of leaving briefings homeless.
    it "falls back to the first thread when the chosen one is archived" do
      ByteConversation.pin_primary!(second)
      second.update!(archived: true)

      expect(ByteConversation.primary_for(user)).to eq(first)
    end
  end

  # The wall is the one thing that must never be picked automatically, and it's
  # also a legitimate choice — somebody could genuinely want the tablet to be
  # where their briefing shows up.
  it "still lands on the wall when it's the only thread there is" do
    second.destroy!
    first.update!(metadata: { "kiosk" => true })

    expect(ByteConversation.for_self_initiated(user)).to eq(first)
  end

  describe "what rides on it" do
    before { ByteConversation.pin_primary!(second) }

    it "is where a scheduled reminder says it will fire" do
      ctx  = Buddy::ToolContext.new(user, conversation: first)
      tool = Buddy::Tools[:schedule_reminder]
      args = { text: "Water the plants", at: 2.hours.from_now.iso8601 }
      result = tool[:execute].call(args.merge(tool[:confirm].call(args, ctx)[:resolved]), ctx)

      expect(BuddyReminder.find(result[:reminder_id]).byte_conversation).to eq(second)
    end

    # Asked from inside the first thread, and it still points at the primary:
    # a reminder is about weeks from now, not about which window is open.
    it "is where a scheduled trigger announces a skip" do
      trigger = ScheduledTrigger.create!(
        user_id: user.id, trigger: "villager", execute_at: 1.minute.from_now, data: {},
      )

      expect(trigger.buddy_conversation).to eq(second)
    end
  end

  describe "the wire payload" do
    it "carries the explicit flag" do
      ByteConversation.pin_primary!(second)

      expect(second.reload.as_wire[:primary]).to be(true)
      expect(first.reload.as_wire[:primary]).to be(false)
    end

    # The first thread claims it on creation, so the flag is truthful about the
    # thread that actually holds it rather than the answer being re-derived on
    # every read.
    it "is already flagged on the first thread, without anyone choosing" do
      expect(first.reload).to be_primary
      expect(second.reload).not_to be_primary
    end

    # A row that predates the claim callback. `primary_among` still answers, so
    # the resolved id on the conversations index is right either way — which is
    # why that value travels separately from the per-row flag.
    it "still resolves when nothing carries the flag at all" do
      user.byte_conversations.update_all(primary_at: nil)

      expect(ByteConversation.primary_for(user)).to eq(first)
      expect(first.reload.as_wire[:primary]).to be(false)
    end
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

    it "takes a single query when nothing is loaded" do
      expect(queries { ByteConversation.for_self_initiated(user) }.length).to eq(1)
    end

    # Both branches, one query — `ordered` is what makes the fallback free,
    # since it's just the first row of a list already fetched.
    it "takes a single query on the fallback path too" do
      user.byte_conversations.update_all(primary_at: nil)
      first.update!(metadata: { "kiosk" => true })
      second.update!(metadata: { "kiosk" => true })

      expect(queries { ByteConversation.for_self_initiated(user) }.length).to eq(1)
    end
  end
end
