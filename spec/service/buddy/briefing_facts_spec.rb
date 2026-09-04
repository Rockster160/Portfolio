require "rails_helper"

# The day, decided in Ruby. A briefing turn is offered no lookup at all, so
# anything this doesn't collect is something the companion cannot mention and
# anything it collects badly is something it will mention badly.
RSpec.describe Buddy::BriefingFacts do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:tz)    { ActiveSupport::TimeZone["America/Denver"] }

  before { allow(user).to receive(:timezone).and_return("America/Denver") }

  # Rocco, 2026-09-04: "we also want to make sure that we are collecting all of
  # the information that Buddy previously was collecting. Reminders, memories,
  # and anything else that Buddy normally would have looked at and collected, we
  # should be collecting, determining if it should be included or not, and then
  # providing it."
  #
  # An absence is a silent decision unless it is written down, and there is no
  # longer a model on the other side that can go and look for what it's missing.
  describe "the decision recorded for every section" do
    it "covers everything Buddy can reach" do
      expect(Buddy::GPT::ContextTool::SECTIONS - described_class::SECTION_DECISIONS.keys).to be_empty
    end

    it "gives a reason for each one it leaves out" do
      dropped = described_class::SECTION_DECISIONS.compact

      expect(dropped.values).to all(be_present)
    end

    it "collects the ones it keeps" do
      expect(described_class::SECTIONS).to contain_exactly(
        :today_notable, :upcoming_notable, :upcoming_reminders,
        :chores_due_today, :stashed_ideas, :pending_relays
      )
    end
  end

  # Rocco: "We don't want Alpine included every day - only the days with
  # precipitation during the desired hours, otherwise it gets ignored/dropped
  # from the data and the prompt entirely."
  describe "Alpine on a dry day" do
    before {
      allow(described_class).to receive(:alpine?).and_return(true)
      allow(Buddy::PlungeAdvisor).to receive_messages(briefing_lines: [], week_rain_lines: [])
    }

    it "leaves the key out of the facts, not an empty one in" do
      expect(described_class.build(user, convo)[:alpine]).to eq({})
    end

    it "takes the heading and the rule out of the seed with it" do
      seed = Buddy::TodayBriefing.seed(user, convo)

      expect(seed).not_to include("ALPINE")
      expect(seed).not_to include("Alpine only ever comes up")
    end

    it "is there on a wet one" do
      allow(Buddy::PlungeAdvisor).to receive_messages(
        briefing_lines:  ["Rain in the forecast", "Rain in Alpine 6pm-8pm"],
        week_rain_lines: [],
      )

      seed = Buddy::TodayBriefing.seed(user, convo)

      expect(seed).to include("ALPINE")
      expect(seed).to include("Rain in Alpine 6pm-8pm")
      expect(seed).to include("Give the hours wherever there are hours")
    end
  end

  # A question somebody in the house asked and is still waiting on IS part of
  # the day, and it was reachable through `get_context` before a briefing turn
  # stopped being offered one.
  describe "a question waiting on them" do
    let(:partner) { create(:user) }

    before {
      BuddyRelay.create!(
        from_user: partner, to_user: user, to_conversation: convo,
        kind: :ask_open, status: :delivered, body: "Are we still on for Thursday?"
      )
    }

    it "is collected" do
      expect(described_class.build(user, convo)[:waiting].pluck(:question))
        .to include("Are we still on for Thursday?")
    end

    it "reaches the seed with who asked it" do
      seed = Buddy::TodayBriefing.seed(user, convo)

      expect(seed).to include("WAITING ON THEM")
      expect(seed).to include("asked: Are we still on for Thursday?")
      expect(seed).to include("Say who asked and what")
    end
  end

  # Rocco: "Buddy should NOT bring things up like 'Oh, I'm going to check up on
  # you today' just because there is a check up today."
  #
  # A check-in is Buddy's own plan to ask about something later, scheduled per
  # record on `BuddyMemory#check_in_at` (Buddy::CheckIns). It speaks for itself
  # when it fires, and a briefing that announces it is announcing Buddy rather
  # than the day.
  describe "a check-in scheduled for today" do
    before {
      BuddyMemory.create!(
        user: user, kind: :followup, content: "Ask how the interview went.",
        check_in_at: 4.hours.from_now, relevant_at: 4.hours.from_now
      )
    }

    it "is not in the facts" do
      facts = described_class.build(user, convo)

      expect(facts.values.flatten.map(&:to_s).join(" ")).not_to include("Ask how the interview went")
    end

    it "is not in the seed" do
      expect(Buddy::TodayBriefing.seed(user, convo)).not_to include("interview went")
    end
  end

  describe "how a line reads" do
    # Rocco: "'You have yoga tomorrow' is absolutely incorrect. 'Chelsea has
    # yoga tomorrow' is accurate and acceptable."
    it "puts whose it is in front of what it is" do
      line = described_class.agenda_line(
        { time: "4:00 PM", title: "Yoga", mine: false, owner: "Chelsea" }, "Rocco"
      )

      expect(line).to eq("4:00 PM · Chelsea: Yoga")
    end

    it "leaves their own alone" do
      line = described_class.agenda_line({ time: "9:00 AM", title: "Standup" }, "Rocco")

      expect(line).to eq("9:00 AM · Standup")
    end

    it "keeps the departure on the item it belongs to" do
      line = described_class.agenda_line(
        { time: "11:40 AM", title: "Eye Follow Up", leave_by: "11:08 AM", drive_min: 22 }, "Rocco"
      )

      expect(line).to eq("11:40 AM · Eye Follow Up · leave by 11:08 AM (22 min drive)")
    end

    it "says a group of jobs as the group" do
      rows = [
        { id: 1, name: "Gather trash", group: "trash" },
        { id: 2, name: "Take out trash bags", group: "trash" },
        { id: 3, name: "Replace Air Filter", hot: "5x" },
      ]

      expect(described_class.job_lines(rows))
        .to eq(["trash: Gather trash, Take out trash bags", "Replace Air Filter · 5x"])
    end
  end
end
