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

    # A daily 9am and a one-off TOMORROW at 9am are different requests - and the
    # minute window is what says so, since a recurring reminder's `fire_at` is
    # its next fire. Recurring ones used to be excluded from the comparison
    # outright on this reasoning, which threw away the one case where it
    # matters: prod 3448/3449, where the daily noon plant check and a one-off
    # set for the same noon both went off.
    def daily!(body, fire_at)
      BuddyReminder.create!(
        user: user, byte_conversation: convo, body: body,
        fire_at: fire_at, recurrence: { "kind" => "daily", "at" => fire_at.strftime("%H:%M") }
      )
    end

    it "doesn't compare against a recurring reminder due on another day" do
      daily!("Write Doug's card", at - 1.day)

      expect { tool[:confirm].call({ text: "Write Doug's card", at: at.iso8601 }, ctx) }.not_to raise_error
    end

    it "does compare against one about to fire at that very minute" do
      daily!("Write Doug's card", at)

      expect { tool[:confirm].call({ text: "Write Doug's card", at: at.iso8601 }, ctx) }
        .to raise_error(/already set/)
    end
  end

  # Buddy could set a reminder and cancel one, but not MOVE one - so "change the
  # tomato reminder to 3pm" came out as a second reminder with the original
  # still sitting there, due to fire at the hour they'd just ruled out.
  describe "move_reminder" do
    let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }
    let(:tool) { Buddy::Tools[:move_reminder] }
    let(:at)   { 2.hours.from_now.in_time_zone(user.timezone) }
    let(:later) { 4.hours.from_now.in_time_zone(user.timezone) }

    def existing!(text, when_at=at, recurrence: nil)
      BuddyReminder.create!(
        user: user, byte_conversation: convo, body: text, fire_at: when_at, recurrence: recurrence,
      )
    end

    def move(match, to, text: nil)
      payload  = { match: match, at: to.iso8601, text: text }.compact
      resolved = tool[:confirm].call(payload, ctx)[:resolved]
      Buddy::Tools.dispatch(tool, payload.merge(resolved), ctx)
    end

    it "moves the one that's already set instead of adding another" do
      reminder = existing!("Uncover the tomatoes")

      expect { move("tomatoes", later) }.not_to(change { BuddyReminder.where(user: user).count })
      expect(reminder.reload.fire_at).to be_within(1.minute).of(later)
    end

    it "rewords it when they changed what it should say" do
      reminder = existing!("Uncover the tomatoes")

      move("tomatoes", later, text: "Shade the tomatoes")

      expect(reminder.reload.body).to eq("Shade the tomatoes")
    end

    it "leaves the wording alone when they only moved the time" do
      reminder = existing!("Uncover the tomatoes")

      move("tomatoes", later)

      expect(reminder.reload.body).to eq("Uncover the tomatoes")
    end

    # A daily 9am moved to 9:30 is still daily - the shape survives, only the
    # clock time changes.
    it "keeps a repeating reminder repeating" do
      reminder = existing!("Grab my Loops", recurrence: { "kind" => "daily", "at" => "07:54" })

      move("Loops", later)

      expect(reminder.reload.recurrence["kind"]).to eq("daily")
      expect(reminder.recurrence["at"]).to eq(later.strftime("%H:%M"))
    end

    it "finds it by id as well as by wording" do
      reminder = existing!("Check the dryer")

      move(reminder.id.to_s, later)

      expect(reminder.reload.fire_at).to be_within(1.minute).of(later)
    end

    it "says so rather than silently creating one when nothing matches" do
      expect { move("meatloaf", later) }.to raise_error(/no reminder/i)
    end

    it "refuses a time that's already gone by" do
      existing!("Check the dryer")

      expect { move("dryer", 1.hour.ago.in_time_zone(user.timezone)) }.to raise_error(/gone by/i)
    end

    it "ignores one that's been cancelled" do
      existing!("Check the dryer").update!(cancelled_at: Time.current)

      expect { move("dryer", later) }.to raise_error(/no reminder/i)
    end

    # A one-shot stamps `fired_at` and leaves `pending` the instant it lands,
    # and that instant is exactly when someone says "send me that again
    # tomorrow at 6". Prod 2364 answered it with "couldn't find that reminder
    # to move it" and the whole thing had to be dictated again.
    describe "snoozing one that just fired" do
      it "re-arms it instead of losing it" do
        reminder = existing!("Create a gate for the stairs", 10.minutes.ago)
        reminder.update!(fired_at: 10.minutes.ago)

        expect { move("gate", later) }.not_to(change { BuddyReminder.where(user: user).count })
        expect(reminder.reload.fire_at).to be_within(1.minute).of(later)
      end

      # A new fire_at on a terminal row would just sit there being skipped.
      it "clears the fired stamp so the firer picks it up again" do
        reminder = existing!("Create a gate for the stairs", 10.minutes.ago)
        reminder.update!(fired_at: 10.minutes.ago)

        move("gate", later)

        expect(reminder.reload.fired_at).to be_nil
        expect(BuddyReminder.pending).to include(reminder)
      end

      it "leaves one that fired long ago alone" do
        existing!("Check the dryer", 2.days.ago).update!(fired_at: 2.days.ago)

        expect { move("dryer", later) }.to raise_error(/no reminder/i)
      end

      # A daily that went off this morning and a live one-off tonight can share
      # a word; the one still coming is what they mean.
      it "prefers a still-pending match over a fired one" do
        fired = existing!("Water the tomatoes", 20.minutes.ago)
        fired.update!(fired_at: 20.minutes.ago)
        live = existing!("Water the tomatoes tonight")

        move("tomatoes", later)

        expect(live.reload.fire_at).to be_within(1.minute).of(later)
        expect(fired.reload.fire_at).to be_within(1.minute).of(20.minutes.ago)
      end
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
