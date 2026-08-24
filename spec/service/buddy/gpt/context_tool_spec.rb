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

    # Prod 4482: Byte's briefing named five of Chelsea's items and none of
    # Rocco's own - his Serenity on Thursday was in the window and went
    # unmentioned. The prompt already said a partner's calendar is NEVER the
    # briefing, in three paragraphs. So the ones with no bearing on his day
    # stop arriving, the way the chore roster and `leave_by` already do.
    describe "a partner's calendar" do
      let(:partner) { create(:user) }
      let(:hers) {
        create(:agenda, user: partner).tap { |a| AgendaShare.create!(agenda: a, user: user, permission: :viewer) }
      }
      let(:mine) { user.agendas.order(:id).first }

      def titles(tool, section = "today_notable")
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

      it "drops the one that has no bearing on their day" do
        expect(titles(briefing)).not_to include("Her Yoga")
      end

      it "keeps the one that runs into something of theirs" do
        expect(titles(briefing)).to include("Her IT Call")
      end

      it "never drops one of their own" do
        expect(titles(briefing)).to include("Serenity")
      end

      # "What has Chelsea got on today" is a real question, and it gets asked on
      # an ordinary turn.
      it "hands over the whole lot on an ordinary turn" do
        expect(titles(tool)).to include("Her Yoga", "Her IT Call", "Serenity")
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
