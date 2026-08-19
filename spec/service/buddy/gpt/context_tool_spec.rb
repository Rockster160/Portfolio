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
      expect(briefing_sections(["chores_all"])).to be_empty
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
      expect(briefing_sections(["today_notable"])).to eq(["today_notable"])
      expect(briefing_sections(["lists"])).to eq(["lists"])
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
          metadata: { "today_briefing" => true },
        )
      }
      let!(:other) {
        BuddyReminder.create!(
          user: user, byte_conversation: convo, kind: :reminder,
          body: "Cover the tomatoes.", fire_at: 3.hours.from_now,
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
