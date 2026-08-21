require "rails_helper"

RSpec.describe "a reminder that stops when something happens" do
  # Dev, 4079-4083: "I need to check my printer every 30 minutes until the print
  # finishes." Byte answered "I can set the every-30-minutes part, but I don't
  # have a way to make it stop itself when the print finishes."
  #
  # It was true, and it shouldn't have been. The condition machinery for "when X
  # happens" has been there all along — it's what `remind_when` runs on — and the
  # only missing piece was something for it to switch off.
  #
  # `check` / `check_task` are NOT this. Those decide whether one firing speaks,
  # so a print that finished leaves the reminder alive and asking again tomorrow.
  describe "a reminder that stops when something happens" do
    let(:user) { User.me }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
    }
    let(:tool) { Buddy::Tools[:schedule_reminder] }
    let(:ctx)  { Buddy::ToolContext.new(user, conversation: convo) }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(WebPushNotifications).to receive(:update_count)
    end

    def confirm(args)
      tool[:confirm].call({ text: "Check the printer." }.merge(args), ctx)
    end

    def create!(args)
      payload = { text: "Check the printer." }.merge(args)
      tool[:execute].call(payload.merge(confirm(args)[:resolved]), ctx)
    end

    let(:printer) { { repeat: "every:30-minutes:14:00", stop_when: :deploy } }

    describe "setting one" do
      it "arms a watch that switches the reminder off" do
        result = create!(printer)
        watch  = BuddyWatch.find(result[:stop_watch_id])

        expect(watch).to be_cancels
        expect(watch.cancels_reminder_id).to eq(result[:reminder_id])
        expect(watch).to be_one_shot
      end

      it "watches on the same scope remind_when would" do
        watch = BuddyWatch.find(create!(printer)[:stop_watch_id])

        expect(watch.trigger_scope).to be_present
        expect(watch.body).to be_present
      end

      # The one thing they'd want to correct is the ending, so it has to be on
      # the chip rather than only in the row.
      it "says on the chip that it ends" do
        result = create!(printer)

        expect(tool[:receipt].call(result, ctx)).to include("until a deploy finishes")
      end

      # Dev 4091: the chip read "Byte will remind you every day at 5:19pm" over a
      # row that was going to nudge fourteen times before midnight. The row was
      # right and the read-back was a different reminder — which from the outside
      # is indistinguishable from having built the wrong thing.
      it "reads the intraday rule back as minutes, not as a daily" do
        chip = tool[:receipt].call(create!(printer), ctx)

        expect(chip).to include("every 30 min")
        expect(chip).not_to include("every day")
      end

      # Dev 4095. "Every 30 min from 5:39pm to 11:59pm, when the print finishes"
      # names two endings, and the first one isn't real — it's the placeholder the
      # fire path needs to step at all. An event ending has no hour in it.
      it "names no hour at all when the ending is a thing happening" do
        chip = tool[:receipt].call(create!(printer), ctx)

        expect(chip).not_to include("11:59")
        expect(chip).not_to match(/from .* to /)
        expect(chip).to include("until a deploy finishes")
      end

      # And it genuinely runs round the clock, or an overnight print goes
      # unchecked from midnight until the hour it was set.
      it "runs through the night rather than stopping at bedtime" do
        rec = BuddyReminder.find(create!(printer)[:reminder_id]).recurrence

        expect(rec["at"]).to eq("00:00")
        expect(rec["until_at"]).to eq("23:59")
      end

      it "still names the window when there IS one" do
        chip = tool[:receipt].call(create!({ repeat: "daily:14:00", every_minutes: 30, until_time: "16:00" }), ctx)

        expect(chip).to include("from 2pm to 4pm")
      end

      it "still reads an ordinary daily back as a daily" do
        chip = tool[:receipt].call(create!({ repeat: "daily:09:00" }), ctx)

        expect(chip).to include("every day at 9am")
      end

      it "leaves an ordinary repeat alone" do
        result = create!({ repeat: "daily:09:00" })

        expect(result[:stop_watch_id]).to be_nil
        expect(BuddyWatch.where(user: user).count).to eq(0)
      end

      # A one-off already has an ending, so there's nothing for a stopping rule
      # to end — but the reminder they asked for still gets set.
      it "sets a one-off and skips the stopping rule that makes no sense on it" do
        result = create!({ at: 2.hours.from_now.iso8601, stop_when: :deploy })

        expect(BuddyReminder.find_by(id: result[:reminder_id])).to be_present
        expect(result[:stop_watch_id]).to be_nil
        expect(result[:stop_failed]).to include("a repeating reminder is what a stopping condition ends")
      end

      # Same gate remind_when applies: watching chores would tell somebody
      # without chores when the rest of the house finished theirs. The repeat
      # itself is none of that gate's business.
      it "skips a condition reaching into a feature they don't have, and keeps the repeat" do
        allow(Buddy::Features).to receive(:gated_arg).and_return([:stop_when, :chores])

        result = create!(printer.merge(stop_when: :chore, stop_target: "Dishes"))

        expect(result[:stop_failed]).to include("needs chores")
        expect(BuddyReminder.find_by(id: result[:reminder_id])).to be_present
      end
    end

    describe "when the thing happens" do
      it "switches the reminder off for good" do
        result   = create!(printer)
        watch    = BuddyWatch.find(result[:stop_watch_id])
        reminder = BuddyReminder.find(result[:reminder_id])

        Buddy::WatchMatcher.fire!(watch)

        expect(reminder.reload.cancelled_at).to be_present
      end

      # Nudges stopping is what they'd notice either way; the difference between
      # "it worked" and "it broke" is one sentence.
      it "says it stopped rather than just going quiet" do
        result = create!(printer)
        watch  = BuddyWatch.find(result[:stop_watch_id])

        expect { Buddy::WatchMatcher.fire!(watch) }.to change { convo.byte_messages.count }.by(1)
        expect(convo.byte_messages.last.body).to include("stopped the check-ins")
      end

      it "pushes, since they're away from the app by definition" do
        watch = BuddyWatch.find(create!(printer)[:stop_watch_id])

        Buddy::WatchMatcher.fire!(watch)

        expect(WebPushNotifications).to have_received(:send_to_byte)
      end

      it "says nothing twice if it somehow fires again" do
        watch = BuddyWatch.find(create!(printer)[:stop_watch_id])
        Buddy::WatchMatcher.fire!(watch)

        expect { Buddy::WatchMatcher.fire!(watch.reload) }.not_to(change { convo.byte_messages.count })
      end

      it "shrugs off a reminder that's already gone" do
        result = create!(printer)
        watch  = BuddyWatch.find(result[:stop_watch_id])
        BuddyReminder.find(result[:reminder_id]).destroy!

        expect { Buddy::WatchMatcher.fire!(watch) }.not_to raise_error
      end
    end

    # The stopper is part of the reminder's rule, not a rule of its own.
    # Dev 4085-4087. "The repeat shape for that one didn't take, so I couldn't arm
    # the printer check-in itself." Two separate traps, and either one on its own
    # left the person with nothing.
    describe "the half that works still happens" do
      # "Every 30 minutes" is the one shape with no hour in the sentence, so the
      # model wrote `every:30-minutes` and the parser refused it for having no
      # clock. There is nothing else it could have meant.
      it "starts a sub-day repeat now when no hour was named" do
        travel_to(ActiveSupport::TimeZone[user.timezone].parse("2026-08-20 14:07")) do
          result   = create!({ repeat: "every:30-minutes" })
          reminder = BuddyReminder.find(result[:reminder_id])

          expect(reminder.recurrence["every_minutes"]).to eq(30)
          expect(reminder.recurrence["at"]).to eq("14:07")
        end
      end

      it "still demands an hour for the shapes that need one" do
        expect { confirm({ repeat: "weekly:mon" }) }.to raise_error(/unknown repeat spec/)
        expect { confirm({ repeat: "daily" }) }.to raise_error(/unknown repeat spec/)
      end

      # A stopping rule that can't be built is a reason to set the repeat without
      # one. Raising took the good half down with the bad half.
      it "sets the reminder even when the ending can't be built" do
        allow(Buddy::WatchCondition).to receive(:resolve).and_raise("no listener for that")

        result = create!(printer)

        expect(BuddyReminder.find_by(id: result[:reminder_id])).to be_present
        expect(result[:stop_watch_id]).to be_nil
      end

      # The one thing that must not happen next is a reply describing an ending
      # that isn't there.
      it "tells the model in as many words that the ending is missing" do
        allow(Buddy::WatchCondition).to receive(:resolve).and_raise("no listener for that")

        result = create!(printer)

        expect(result[:stop_failed]).to include("THE REMINDER IS SET")
        expect(result[:stop_failed]).to include("no listener for that")
        expect(result[:stop_failed]).to include("request_feature")
      end

      it "says so on the chip too" do
        allow(Buddy::WatchCondition).to receive(:resolve).and_raise("nope")

        expect(tool[:receipt].call(create!(printer), ctx)).to include("won't stop on its own")
      end
    end

    describe "on the reminders list" do
      # The list showed a repeat with no ending, next to a companion that had
      # just promised one — which reads as the promise being false.
      it "says on the reminder's own row what ends it" do
        create!(printer)

        row = Buddy::ReminderPresenter.rows(user).find { |r| r[:type] == :reminder }

        expect(row[:sublabel]).to include("until a deploy finishes")
      end

      # `human` is minted for the TRIGGER sense, which is right for "tell me when
      # the print finishes" and wrong the moment it's what stops something:
      # "every 30 min, when the print finishes" reads as a second event rather
      # than the point it ends.
      it "reads the ending as an ending, not as another thing that happens" do
        create!(printer)

        row = Buddy::ReminderPresenter.rows(user).find { |r| r[:type] == :reminder }

        expect(row[:sublabel]).to end_with("until a deploy finishes")
        expect(row[:sublabel]).not_to include("when a deploy")
      end

      it "names no hour on that row either" do
        create!(printer)

        row = Buddy::ReminderPresenter.rows(user).find { |r| r[:type] == :reminder }

        expect(row[:sublabel]).to include("every 30 min")
        expect(row[:sublabel]).not_to include("12:00 AM")
      end

      it "still names the hour on an ordinary repeat" do
        create!({ repeat: "daily:09:00" })

        row = Buddy::ReminderPresenter.rows(user).find { |r| r[:type] == :reminder }

        expect(row[:sublabel]).to include("every day at 9:00 AM")
      end

      it "doesn't show up as its own togglable row" do
        create!(printer)

        rows = Buddy::ReminderPresenter.rows(user)

        expect(rows.map { |r| r[:type] }).to eq([:reminder])
      end

      # Otherwise switching the stopper off leaves a repeat with nothing left to
      # end it, which is worse than either state on its own.
      it "goes when the reminder it ends is switched off" do
        result = create!(printer)
        watch  = BuddyWatch.find(result[:stop_watch_id])

        BuddyReminder.find(result[:reminder_id]).update!(cancelled_at: Time.current)

        expect(watch.reload.cancelled_at).to be_present
      end

      it "leaves other people's stoppers alone" do
        other = create!(printer)
        mine  = create!(printer)
        BuddyWatch.find(other[:stop_watch_id]).update!(user: create(:user))

        BuddyReminder.find(mine[:reminder_id]).update!(cancelled_at: Time.current)

        expect(BuddyWatch.find(other[:stop_watch_id]).cancelled_at).to be_nil
      end
    end

    describe "what the companion is told" do
      it "stops claiming it can't be done" do
        schema = Buddy::Tools.function_schema(tool)

        expect(schema[:description]).to include("This is not a thing you lack")
        expect(schema[:description]).to include("stop_when")
      end

      it "separates ending the rule from skipping one firing" do
        schema = Buddy::Tools.function_schema(tool)

        expect(schema[:description]).to include("Use a check to skip, and `stop_when` to finish")
      end

      # Dev 4093-4095: the model reached for THIS tool for "check my printer every
      # 30 minutes", which is a repeat you have to act on each round — so the
      # nudges fire on a clock whether or not you went and looked.
      it "sends a repeat they must act on to the timer instead" do
        schema = Buddy::Tools.function_schema(tool)

        expect(schema[:description]).to include("set_timer(repeat: true)`, NOT THIS")
        expect(schema[:description]).to include("Check the printer every 30 minutes")
      end
    end
  end

  # The same condition, read as an ENDING rather than as a trigger.
  #
  # `WatchCondition#human` is minted for the trigger sense, and every ending in
  # the app renders through it: the reminders list, the cycle rows, both receipt
  # chips. "every 30 min, when the print finishes" reads as two things that
  # happen; "until" is the whole difference between that and a rule.
  describe "the condition read as an ending" do
    describe ".until_phrase" do
      it "turns the trigger phrasing into an ending" do
        expect(Buddy::WatchCondition.until_phrase("when the print finishes")).to eq("until the print finishes")
      end

      it "takes the other ways a condition gets worded" do
        expect(Buddy::WatchCondition.until_phrase("whenever the dryer stops")).to eq("until the dryer stops")
        expect(Buddy::WatchCondition.until_phrase("once I get home")).to eq("until I get home")
        expect(Buddy::WatchCondition.until_phrase("after the deploy lands")).to eq("until the deploy lands")
      end

      it "leaves a phrase that never said when alone, apart from the until" do
        expect(Buddy::WatchCondition.until_phrase("the washer's done")).to eq("until the washer's done")
      end

      it "doesn't eat a `when` in the middle of the sentence" do
        expect(Buddy::WatchCondition.until_phrase("when I get to the shop when it's open"))
          .to eq("until I get to the shop when it's open")
      end

      it "is nil for nothing at all" do
        expect(Buddy::WatchCondition.until_phrase(nil)).to be_nil
        expect(Buddy::WatchCondition.until_phrase("  ")).to be_nil
      end

      # It's the condition the app already builds, not a hand-written string, so
      # the real ones have to come out right.
      it "reads a real resolved condition as an ending" do
        user = User.me
        convo = user.byte_conversations.create!(mode: :buddy, name: "Byte")
        resolved = Buddy::WatchCondition.resolve({ trigger: :deploy }, Buddy::ToolContext.new(user, conversation: convo))

        expect(Buddy::WatchCondition.until_phrase(resolved.human)).to start_with("until ")
      end
    end
  end
end
