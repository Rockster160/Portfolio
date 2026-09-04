require "rails_helper"

RSpec.describe Buddy::GPT::ContextTool do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:tool)  { described_class.new(user, convo) }

  def sections_returned(requested)
    JSON.parse(tool.call({ "sections" => requested })).keys
  end

  # "Turn the fan to low" had the model check jil_triggers, find only "Fan High",
  # and tell the person it couldn't do it - while "Great Fan" (off/low/mid/high)
  # sat in jil_functions the whole time. Which of the two indexes a capability
  # lands in is our filing system, not something the request reveals.
  describe "the two Jil indexes" do
    it "returns both when only the trigger index was asked for" do
      expect(sections_returned(["jil_triggers"])).to include("jil_triggers", "jil_functions")
    end

    it "returns both when only the function index was asked for" do
      expect(sections_returned(["jil_functions"])).to include("jil_triggers", "jil_functions")
    end

    it "does not drag them into an unrelated request" do
      expect(sections_returned(["chores_all"])).to eq(["chores_all"])
    end
  end

  describe "section filtering" do
    it "keeps only sections on the allowlist" do
      expect(sections_returned(%w[chores_all not_a_real_section])).to eq(["chores_all"])
    end

    it "returns everything when nothing specific was asked for" do
      expect(sections_returned([]).length).to be > 1
    end
  end

  # A briefing names what's due today and isn't a habit, or it says nothing
  # about chores. The full roster is WITHHELD from that turn rather than
  # discouraged: "THREE NAMES, TOTAL", "a daily is never one of your three" and
  # a re-sorted bucket all failed in a row, because a list in context gets read
  # out no matter what the sentence above it says.
  describe "a Today briefing turn" do
    let(:briefing) { described_class.new(user, convo, briefing: true) }

    def briefing_sections(requested)
      JSON.parse(briefing.call({ "sections" => requested })).keys
    end

    it "hands over the due-today list and no other chore section" do
      create(:chore, name: "Gutters", created_by_user: user, marked_due_at: Time.current)
      returned = briefing_sections([])

      expect(returned).to include("chores_due_today")
      expect(returned.grep(/\Achores_/)).to eq(["chores_due_today"])
    end

    it "refuses the full roster even when it's asked for by name" do
      expect(briefing_sections(["chores_pending_today"])).not_to include("chores_pending_today")
      expect(briefing_sections(["chores_all"])).not_to include("chores_all")
    end

    # Asking only for things this turn can't have used to come back with the
    # ENTIRE context, which is the opposite of withholding one.
    it "does not answer a refused request with everything there is" do
      expect(briefing_sections(["chores_all"]).length).to be < described_class::SECTIONS.length
    end

    it "cannot even name them: they're off the schema enum" do
      enum = described_class.schema(user: user, briefing: true)
        .dig(:parameters, :properties, :sections, :items, :enum)

      expect(enum).to include(:chores_due_today)
      expect(enum.grep(/\Achores_/)).to eq([:chores_due_today])
    end

    # The calendar's standing repeats are withheld for the same reason the
    # chore roster is: they describe an ordinary week, and whatever list is
    # present gets read out. What's left is the part of the day that differs.
    it "swaps the full calendar for the notable view" do
      returned = briefing_sections([])

      expect(returned).to include("today_notable", "upcoming_notable")
      expect(returned).not_to include("today_agenda", "upcoming_agenda")
    end

    it "leaves everything that isn't routine alone" do
      expect(briefing_sections(["today_notable"])).to include("today_notable")
      expect(briefing_sections(["lists"])).to include("lists")
      expect(briefing_sections(["lists"])).not_to include("chores_all", "today_agenda")
    end

    # Prod 3951 signed off with "there's one reminder in play already: Today
    # briefing." That's the row that FIRED this turn — it rolls forward to
    # tomorrow the moment it goes off, landing back inside the 48h window while
    # the briefing it caused is still being written.
    describe "the reminder that caused the briefing" do
      # Mid-morning, so "3 hours from now" is unambiguously still today and the
      # day filter below has nothing to say about it.
      around { |example| travel_to(Time.utc(2026, 9, 4, 15, 0)) { example.run } }

      def reminder_bodies(tool)
        rows = JSON.parse(tool.call({ "sections" => ["upcoming_reminders"] }))["upcoming_reminders"]
        rows.to_a.pluck("body")
      end

      let!(:own) {
        BuddyReminder.create!(
          user: user, byte_conversation: convo, kind: :reminder,
          body: Buddy::TodaySchedule::BODY, fire_at: 23.hours.from_now,
          recurrence: { "freq" => "daily", "at" => "08:30" },
          action: { "tool" => "today_briefing", "payload" => {} },
          metadata: { "today_briefing" => true }
        )
      }
      let!(:other) {
        BuddyReminder.create!(
          user: user, byte_conversation: convo, kind: :reminder,
          body: "Cover the tomatoes.", fire_at: 3.hours.from_now
        )
      }

      it "is not in front of the briefing that it started" do
        expect(reminder_bodies(briefing)).not_to include(Buddy::TodaySchedule::BODY)
      end

      # Half of somebody's day can live in reminders, so this takes one row
      # rather than the section.
      it "leaves every other reminder where it is" do
        expect(reminder_bodies(briefing)).to include("Cover the tomatoes.")
      end

      # "When's my next briefing?" is a real question, and an ordinary turn is
      # where it gets asked.
      it "is still there on an ordinary turn" do
        expect(reminder_bodies(tool)).to include(Buddy::TodaySchedule::BODY)
      end

      # Prod 4020, hours after the briefing-turn guard shipped: "what's
      # happening tomorrow?" came back "that Today briefing reminder is still
      # sitting there from this morning." Present is right; unlabelled is not.
      it "is labelled on an ordinary turn, so it doesn't read as a job of theirs" do
        rows = JSON.parse(tool.call({ "sections" => ["upcoming_reminders"] }))["upcoming_reminders"]
        mine = rows.find { |r| r["body"] == Buddy::TodaySchedule::BODY }

        expect(mine["own_briefing"]).to be(true)
        expect(rows.find { |r| r["body"] == "Cover the tomatoes." }).not_to have_key("own_briefing")
      end
    end

    # Prod 5254, 3 Sep: Suki opened with "your propagation check is back around
    # again, and it's due at 10 AM". Reminder 52 is a four-day cadence, last
    # fired 31 Aug, next due the 4th - it was never due that day, and nothing
    # arrived at 10. The row was right; the sentence built from it was not.
    #
    # `upcoming_reminders` runs a 48-hour window and stamps "%a %-I:%M %p", so
    # tomorrow's arrived reading "Fri 10:00 AM" with nothing but a weekday name
    # to say it wasn't this morning. A four-day rhythm isn't routine, so the
    # cadence filter didn't touch it.
    describe "a reminder that belongs to another day" do
      around { |example| travel_to(Time.utc(2026, 9, 4, 15, 0)) { example.run } }

      def reminder_bodies(tool)
        rows = JSON.parse(tool.call({ "sections" => ["upcoming_reminders"] }))["upcoming_reminders"]
        rows.to_a.pluck("body")
      end

      let!(:today) {
        BuddyReminder.create!(
          user: user, byte_conversation: convo, kind: :reminder,
          body: "Feed the fish.", fire_at: 3.hours.from_now
        )
      }
      let!(:tomorrow) {
        BuddyReminder.create!(
          user: user, byte_conversation: convo, kind: :reminder,
          body: "Check the propagations.", fire_at: 27.hours.from_now,
          recurrence: { "freq" => "custom", "unit" => "day", "interval" => 4, "at" => "10:00" }
        )
      }

      it "is not in front of a briefing about today" do
        expect(reminder_bodies(briefing)).not_to include("Check the propagations.")
      end

      it "leaves today's alone" do
        expect(reminder_bodies(briefing)).to include("Feed the fish.")
      end

      # "What have I got coming up" is a question about the window, and every
      # turn that isn't a briefing keeps all 48 hours of it.
      it "is still there on an ordinary turn" do
        expect(reminder_bodies(tool)).to include("Check the propagations.")
      end
    end

    # Prod 4482: Byte's briefing named five of Chelsea's items and none of
    # Rocco's own - his Serenity on Thursday was in the window and went
    # unmentioned. The prompt already said a partner's calendar is NEVER the
    # briefing, in three paragraphs. So the ones with no bearing on his day
    # stop arriving, the way the chore roster and `leave_by` already do.
    describe "a partner's calendar" do
      # Every time here is placed relative to now, and the suite runs at
      # whatever o'clock it runs at: late in the evening "3 hours from now" is
      # tomorrow, and every one of these items fell out of today's window, so
      # the block passed and failed by the clock rather than by the filter it
      # is about. Pinned to a Monday morning, which is also what the weekly
      # rules below need in order to have materialized anything.
      around { |example| travel_to(Time.utc(2026, 8, 24, 15, 0)) { example.run } }

      let(:partner) { create(:user) }
      let(:hers) {
        create(:agenda, user: partner).tap { |a| AgendaShare.create!(agenda: a, user: user, permission: :viewer) }
      }
      let(:mine) { user.agendas.order(:id).first }

      def titles(tool, section="today_notable")
        JSON.parse(tool.call({ "sections" => [section] }))[section].to_a.pluck("title")
      end

      before do
        AgendaItem.create!(agenda: mine, name: "Serenity", kind: :event,
                           start_at: 3.hours.from_now, end_at: 4.hours.from_now, status: :confirmed)
        AgendaItem.create!(agenda: hers, name: "Her Yoga", kind: :event,
                           start_at: 6.hours.from_now, end_at: 7.hours.from_now, status: :confirmed)
        AgendaItem.create!(agenda: hers, name: "Her IT Call", kind: :event,
                           start_at: 3.hours.from_now + 30.minutes, end_at: 5.hours.from_now, status: :confirmed)
      end

      # Rocco, 2026-09-04: "we WANT the partner events to be visible, we do NOT
      # want them treated as our own. 'You have yoga tomorrow' is absolutely
      # incorrect. 'Chelsea has yoga tomorrow' is accurate and acceptable."
      #
      # So the collision test stopped deciding what TODAY shows. What answers
      # prod 4482 now is the shape of the line rather than its absence:
      # Buddy::BriefingFacts puts the owner in front of the title, so the row
      # reads as hers before the model has written a word.
      it "keeps today's, whether or not it touches their own day" do
        expect(titles(briefing)).to include("Her Yoga", "Her IT Call")
      end

      # "(Although it should only be bringing up today's except for
      # specifically noticeable events)" — the week is their own.
      it "keeps a partner out of the week" do
        AgendaItem.create!(agenda: hers, name: "Her Thursday", kind: :event,
                           start_at: 3.days.from_now, end_at: 3.days.from_now + 1.hour, status: :confirmed)

        expect(titles(briefing, "upcoming_notable")).not_to include("Her Thursday")
      end

      it "never drops one of their own" do
        expect(titles(briefing)).to include("Serenity")
      end

      # "What has Chelsea got on today" is a real question, and it gets asked on
      # an ordinary turn.
      it "hands over the whole lot on an ordinary turn" do
        expect(titles(tool)).to include("Her Yoga", "Her IT Call", "Serenity")
      end

      def row(tool, title)
        JSON.parse(tool.call({ "sections" => ["today_notable"] }))["today_notable"]
          .to_a.find { |i| i["title"] == title }
      end

      # Prod 4524 opened Byte's briefing with Chelsea's yoga as Rocco's own. Two
      # people doing two different things at the same hour is not a clash, and
      # a tag naming what it runs into is an invitation to write one.
      it "does not tell a briefing what a partner's item runs into" do
        expect(row(briefing, "Her IT Call")).not_to have_key("collides_with")
      end

      # "Does her thing run into my Serenity?" is a real question, and an
      # ordinary turn is where it gets asked.
      it "names it on an ordinary turn, where the comparison is the question" do
        expect(row(tool, "Her IT Call")["collides_with"]).to eq("Serenity")
      end
    end

    # Prod 4490 opened Moss's briefing with "Yoga already passed", and prod
    # 4488 had Suki volunteer that a reminder cancelled six days earlier "is
    # not coming at you today". Both are named in `today_briefing.rb` as the
    # thing not to do - "not as a summary, not as a count, not as a passing
    # note that the morning one already went", and a switched-off reminder is
    # in context "so you can ANSWER about them when asked, and for no other
    # reason". Three instances across three companions in two days, and prose
    # was the only thing holding it.
    describe "things that have already finished" do
      around { |example| travel_to(Time.utc(2026, 8, 24, 20, 0)) { example.run } }

      let(:mine) { user.agendas.order(:id).first }

      def titles(tool)
        JSON.parse(tool.call({ "sections" => ["today_notable"] }))["today_notable"].to_a.pluck("title")
      end

      def reminder_bodies(tool)
        rows = JSON.parse(tool.call({ "sections" => ["upcoming_reminders"] }))["upcoming_reminders"]
        rows.to_a.pluck("body")
      end

      before do
        AgendaItem.create!(agenda: mine, name: "Morning Yoga", kind: :event,
                           start_at: 5.hours.ago, end_at: 4.hours.ago, status: :confirmed)
        AgendaItem.create!(agenda: mine, name: "Tech Retro", kind: :event,
                           start_at: 2.hours.from_now, end_at: 3.hours.from_now, status: :confirmed)
        BuddyReminder.create!(user: user, byte_conversation: convo, kind: :reminder,
                              body: "Check the plants.", fire_at: 2.hours.from_now,
                              cancelled_at: 6.days.ago)
      end

      it "leaves the one that already went out of the briefing" do
        expect(titles(briefing)).not_to include("Morning Yoga")
      end

      it "keeps the rest of the day" do
        expect(titles(briefing)).to include("Tech Retro")
      end

      it "leaves a switched-off reminder out of the briefing" do
        expect(reminder_bodies(briefing)).not_to include("Check the plants.")
      end

      # "Did my yoga already happen?" and "is the plant check still on?" are
      # real questions, and an ordinary turn is where they get asked.
      it "hands both over on an ordinary turn" do
        expect(titles(tool)).to include("Morning Yoga")
        expect(reminder_bodies(tool)).to include("Check the plants.")
      end

      # Prod 4980 opened on "Whisper nap sound just went off" — reminder 69, a
      # one-off that had rung twenty hours earlier — and then named nothing
      # still ahead. A rung one-off is the only row in `upcoming_reminders`
      # shaped like an event, and on a quiet morning that is what gets reached
      # for. It stays everywhere else: prod 3255 is a briefing re-dating one
      # forward off the thread with nothing in context to argue.
      describe "a one-off that already rang" do
        let!(:rang) {
          BuddyReminder.create!(user: user, byte_conversation: convo, kind: :reminder,
                                body: "Whisper nap sound.", fire_at: 20.hours.ago,
                                fired_at: 20.hours.ago)
        }

        it "is marked as history rather than dropped from the context" do
          rows = JSON.parse(tool.call({ "sections" => ["upcoming_reminders"] }))["upcoming_reminders"]
          mine = rows.to_a.find { |r| r["body"] == "Whisper nap sound." }

          expect(mine["status"]).to eq("already_rang")
        end

        it "is not in front of a briefing" do
          expect(reminder_bodies(briefing)).not_to include("Whisper nap sound.")
        end

        it "is still there on an ordinary turn, where the question gets asked" do
          expect(reminder_bodies(tool)).to include("Whisper nap sound.")
        end

        it "does not take the still-due ones with it" do
          BuddyReminder.create!(user: user, byte_conversation: convo, kind: :reminder,
                                body: "Collect the parcel.", fire_at: 2.hours.from_now)

          expect(reminder_bodies(briefing)).to include("Collect the parcel.")
        end
      end
    end

    # Prod 4985: "Nothing's due today, so your morning looks pretty open for
    # now", on a day Chelsea logged three chore completions. `chores_due_today`
    # is the exceptions list — the daily rotation is deliberately not in it — so
    # empty means "nothing unusual", never "nothing to do", and the seed says so
    # in bold twice. Buddy::GPT::Turn#without_empty_chore_note needs the
    # sentence to NAME chores and this one named nothing.
    describe "an empty due-today chore list" do
      def chore_rows(tool)
        JSON.parse(tool.call({ "sections" => ["chores_due_today"] }))
      end

      it "is not handed to a briefing at all" do
        expect(chore_rows(briefing)).not_to have_key("chores_due_today")
      end

      it "still arrives on an ordinary turn" do
        expect(chore_rows(tool)).to have_key("chores_due_today")
      end

      it "leaves a list with something in it alone" do
        create(:chore, name: "Gutters", created_by_user: user, marked_due_at: Time.current)

        expect(chore_rows(briefing)["chores_due_today"].to_a.pluck("name")).to eq(["Gutters"])
      end
    end

    # Rocco, 2026-08-28: "We don't want Byte to include all of the every-day
    # reminders in the briefing as it fills it with extra text that's not
    # needed." The calendar half of the day has always been narrowed to the
    # exceptions; the reminder half never was, so the same standing nudges came
    # back every morning with a clock time on each.
    describe "the standing daily nudges" do
      # Mid-morning, because a briefing only sees TODAY's reminders now
      # (#without_other_days) and "7 hours from now" is tomorrow if the suite
      # happens to run in the evening.
      around { |example| travel_to(Time.utc(2026, 9, 4, 15, 0)) { example.run } }

      def reminder_bodies(tool)
        rows = JSON.parse(tool.call({ "sections" => ["upcoming_reminders"] }))["upcoming_reminders"]
        rows.to_a.pluck("body")
      end

      before do
        BuddyReminder.create!(user: user, byte_conversation: convo, kind: :reminder,
                              body: "Do Dishes.", fire_at: 4.hours.from_now,
                              recurrence: { "freq" => "daily", "at" => "15:00" })
        BuddyReminder.create!(user: user, byte_conversation: convo, kind: :reminder,
                              body: "Stand up and stretch.", fire_at: 5.hours.from_now,
                              recurrence: { "freq" => "weekdays", "at" => "11:00" })
        BuddyReminder.create!(user: user, byte_conversation: convo, kind: :reminder,
                              body: "Water the ferns.", fire_at: 6.hours.from_now,
                              recurrence: { "freq" => "weekly", "at" => "18:00", "by_day" => ["sunday"] })
        BuddyReminder.create!(user: user, byte_conversation: convo, kind: :reminder,
                              body: "Call the vet back.", fire_at: 7.hours.from_now)
      end

      it "leaves a daily one out of the briefing" do
        expect(reminder_bodies(briefing)).not_to include("Do Dishes.")
      end

      it "leaves an every-weekday one out too" do
        expect(reminder_bodies(briefing)).not_to include("Stand up and stretch.")
      end

      # The whole point of the cut. A weekly or monthly nudge is exactly the
      # thing somebody doesn't have top of mind, which is what makes it news.
      it "keeps a weekly one, which is not something anybody knows cold" do
        expect(reminder_bodies(briefing)).to include("Water the ferns.")
      end

      it "keeps a one-off" do
        expect(reminder_bodies(briefing)).to include("Call the vet back.")
      end

      # "What reminders do I have?" and "move the dishes one to 9" both need
      # the row. The narrowing is the briefing's, not the person's.
      it "hands every one of them over on an ordinary turn" do
        expect(reminder_bodies(tool)).to include(
          "Do Dishes.", "Stand up and stretch.", "Water the ferns.", "Call the vet back."
        )
      end
    end

    # Prod 3954: "a very open day ahead, with nothing pressing" at 8:30, with
    # two reminders due at 9:00 and one at 10:00. The seed said which reminders
    # to leave OUT and never said to go and get them, so a briefing that didn't
    # think to ask wrote the day without them.
    describe "reminders" do
      it "arrive whether or not the briefing thought to ask" do
        expect(briefing_sections(["today_notable"])).to include("upcoming_reminders")
      end

      it "are not forced into an ordinary turn that asked for something else" do
        expect(sections_returned(["today_notable"])).to eq(["today_notable"])
      end
    end

    # Asking about chores directly is a different thing entirely, and still
    # gets the whole list — the narrowing is the briefing's, not the person's.
    it "does not narrow an ordinary turn" do
      expect(sections_returned(["chores_pending_today"])).to include("chores_pending_today")

      enum = described_class.schema(user: user)
        .dig(:parameters, :properties, :sections, :items, :enum)
      expect(enum).to include(:chores_pending_today, :chores_all)
    end
  end
end
