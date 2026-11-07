require "rails_helper"

RSpec.describe "a reminder that stops when something happens" do
  # `stop_when` arms a one-shot watch on the same condition machinery
  # `remind_when` runs on, which switches the repeating reminder off.
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
    end

    def confirm(args)
      tool[:confirm].call({ text: "Check the printer." }.merge(args), ctx)
    end

    def create!(args)
      payload = { text: "Check the printer." }.merge(args)
      tool[:execute].call(payload.merge(confirm(args)[:resolved]), ctx)
    end

    let(:printer) { { repeat: "every:30-minutes:14:00", stop_when: :deploy } }

    def receipt(args)
      tool[:receipt].call(create!(args), ctx)
    end

    def reminder_row
      Buddy::ReminderPresenter.rows(user).find { |r| r[:type] == :reminder }
    end

    describe "setting one" do
      # It genuinely runs round the clock, or an overnight print goes unchecked
      # from midnight until the hour it was set.
      it "arms a one-shot watch that switches the reminder off, and repeats round the clock", :aggregate_failures do
        result = create!(printer)
        watch  = BuddyWatch.find(result[:stop_watch_id])

        expect(watch).to be_cancels
        expect(watch.cancels_reminder_id).to eq(result[:reminder_id])
        expect(watch).to be_one_shot
        expect(watch.trigger_scope).to be_present
        expect(watch.body).to be_present

        rec = BuddyReminder.find(result[:reminder_id]).recurrence
        expect(rec["at"]).to eq("00:00")
        expect(rec["until_at"]).to eq("23:59")
      end

      # The read-back is what tells them they built the right thing: an
      # intraday rule as minutes, an event ending with no placeholder hour, and
      # the ending itself, since that is the part they'd want to correct.
      it "reads the rule and its ending back on the chip", :aggregate_failures do
        chip = receipt(printer)
        expect(chip).to include("every 30 min", "until a deploy finishes")
        expect(chip).not_to include("every day")
        expect(chip).not_to include("11:59")
        expect(chip).not_to match(/from .* to /)

        expect(receipt({ repeat: "daily:14:00", every_minutes: 30, until_time: "16:00" })).to include("from 2pm to 4pm")
        expect(receipt({ repeat: "daily:09:00" })).to include("every day at 9am")
      end

      it "leaves an ordinary repeat without a stopper" do
        result = create!({ repeat: "daily:09:00" })

        expect(result[:stop_watch_id]).to be_nil
        expect(BuddyWatch.where(user: user).count).to eq(0)
      end

      # A one-off already has an ending; a condition reaching into a feature
      # they don't have is gated the way remind_when gates it. Either way the
      # reminder they asked for still gets set.
      it "skips a stopping rule on a one-off, or one reaching into a feature they lack, but sets the reminder", :aggregate_failures do
        result = create!({ at: 2.hours.from_now.iso8601, stop_when: :deploy })
        expect(BuddyReminder.find_by(id: result[:reminder_id])).to be_present
        expect(result[:stop_watch_id]).to be_nil
        expect(result[:stop_failed]).to be_present

        allow(Buddy::Features).to receive(:gated_arg).and_return([:stop_when, :chores])
        result = create!(printer.merge(stop_when: :chore, stop_target: "Dishes"))
        expect(result[:stop_failed]).to be_present
        expect(BuddyReminder.find_by(id: result[:reminder_id])).to be_present
      end
    end

    describe "when the thing happens" do
      # They're away from the app by definition, and the difference between "it
      # worked" and "it broke" is one pushed message.
      it "switches the reminder off for good, says so once, and pushes", :aggregate_failures do
        result   = create!(printer)
        watch    = BuddyWatch.find(result[:stop_watch_id])
        reminder = BuddyReminder.find(result[:reminder_id])

        expect { Buddy::WatchMatcher.fire!(watch) }.to change { convo.byte_messages.count }.by(1)
        expect(reminder.reload.cancelled_at).to be_present
        expect(WebPushNotifications).to have_received(:send_to_byte)

        expect { Buddy::WatchMatcher.fire!(watch.reload) }.not_to(change { convo.byte_messages.count })
      end

      it "shrugs off a reminder that's already gone" do
        result = create!(printer)
        watch  = BuddyWatch.find(result[:stop_watch_id])
        BuddyReminder.find(result[:reminder_id]).destroy!

        expect { Buddy::WatchMatcher.fire!(watch) }.not_to raise_error
      end
    end

    describe "the half that works still happens" do
      # "Every 30 minutes" is the one shape with no hour in the sentence, and
      # there is nothing else it could have meant.
      it "starts a sub-day repeat now when no hour was named", :aggregate_failures do
        travel_to(ActiveSupport::TimeZone[user.timezone].parse("2026-08-20 14:07")) do
          reminder = BuddyReminder.find(create!({ repeat: "every:30-minutes" })[:reminder_id])

          expect(reminder.recurrence["every_minutes"]).to eq(30)
          expect(reminder.recurrence["at"]).to eq("14:07")
        end
      end

      it "still demands an hour for the shapes that need one", :aggregate_failures do
        expect { confirm({ repeat: "weekly:mon" }) }.to raise_error(/unknown repeat spec/)
        expect { confirm({ repeat: "daily" }) }.to raise_error(/unknown repeat spec/)
      end

      # Raising took the good half down with the bad half, and the reply must
      # not describe an ending that isn't there.
      it "sets the reminder even when the ending can't be built, and hands back why", :aggregate_failures do
        allow(Buddy::WatchCondition).to receive(:resolve).and_raise("no listener for that")

        result = create!(printer)

        expect(BuddyReminder.find_by(id: result[:reminder_id])).to be_present
        expect(result[:stop_watch_id]).to be_nil
        expect(result[:stop_failed]).to include("no listener for that")
        expect(tool[:receipt].call(result, ctx)).not_to include("until a deploy finishes")
      end
    end

    describe "on the reminders list" do
      # The ending reads as an ending ("until"), not as another thing that
      # happens, and the stopper is part of the reminder's rule rather than a
      # row of its own.
      it "shows the ending on the reminder's own row, with no hour and no row for the stopper", :aggregate_failures do
        create!(printer)

        expect(Buddy::ReminderPresenter.rows(user).map { |r| r[:type] }).to eq([:reminder])
        expect(reminder_row[:sublabel]).to include("every 30 min")
        expect(reminder_row[:sublabel]).to end_with("until a deploy finishes")
        expect(reminder_row[:sublabel]).not_to include("when a deploy")
        expect(reminder_row[:sublabel]).not_to include("12:00 AM")
      end

      it "still names the hour on an ordinary repeat" do
        create!({ repeat: "daily:09:00" })

        expect(reminder_row[:sublabel]).to include("every day at 9am")
      end

      # Otherwise switching the stopper off leaves a repeat with nothing left to
      # end it, which is worse than either state on its own.
      it "goes when the reminder it ends is switched off, leaving other people's alone", :aggregate_failures do
        other = create!(printer)
        mine  = create!(printer)
        BuddyWatch.find(other[:stop_watch_id]).update!(user: create(:user))

        BuddyReminder.find(mine[:reminder_id]).update!(cancelled_at: Time.current)

        expect(BuddyWatch.find(mine[:stop_watch_id]).cancelled_at).to be_present
        expect(BuddyWatch.find(other[:stop_watch_id]).cancelled_at).to be_nil
      end
    end
  end

  # `WatchCondition#human` is minted for the trigger sense, and every ending in
  # the app renders through `until_phrase`.
  describe "the condition read as an ending" do
    it "turns the trigger phrasing into an ending", :aggregate_failures do
      [
        ["when the print finishes", "until the print finishes"],
        ["whenever the dryer stops", "until the dryer stops"],
        ["once I get home", "until I get home"],
        ["after the deploy lands", "until the deploy lands"],
        ["the washer's done", "until the washer's done"],
        # A `when` in the middle of the sentence is left alone.
        ["when I get to the shop when it's open", "until I get to the shop when it's open"],
      ].each do |phrase, expected|
        expect(Buddy::WatchCondition.until_phrase(phrase)).to eq(expected), phrase
      end
      expect(Buddy::WatchCondition.until_phrase(nil)).to be_nil
      expect(Buddy::WatchCondition.until_phrase("  ")).to be_nil
    end

    it "reads a real resolved condition as an ending" do
      user = User.me
      convo = user.byte_conversations.create!(mode: :buddy, name: "Byte")
      resolved = Buddy::WatchCondition.resolve({ trigger: :deploy }, Buddy::ToolContext.new(user, conversation: convo))

      expect(Buddy::WatchCondition.until_phrase(resolved.human)).to start_with("until ")
    end
  end
end
