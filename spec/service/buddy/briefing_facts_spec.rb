require "rails_helper"

# The day, decided in Ruby. A briefing turn is offered no lookup at all, so
# anything this doesn't collect is something the companion cannot mention and
# anything it collects badly is something it will mention badly.
RSpec.describe Buddy::BriefingFacts do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:tz)    { ActiveSupport::TimeZone["America/Denver"] }

  before { allow(user).to receive(:timezone).and_return("America/Denver") }

  # An absence is a silent decision unless it is written down, so every section
  # Buddy can reach has a recorded decision, and every one left out says why.
  it "records a decision for every section Buddy can reach" do
    expect(Buddy::GPT::ContextTool::SECTIONS - described_class::SECTION_DECISIONS.keys).to be_empty
    expect(described_class::SECTION_DECISIONS.compact.values).to all(be_present)
  end

  # Alpine is the owner's plunge spot; for everybody else it is a town whose
  # forecast they have no reason to hear.
  describe "whose forecast Alpine is" do
    before {
      allow(Buddy::PlungeAdvisor).to receive_messages(
        briefing_lines:  ["Rain in the forecast for Alpine today.", "Rain in Alpine 7pm-1am"],
        week_rain_lines: [],
      )
    }

    it "is his, when it is wet" do
      allow(user).to receive(:me?).and_return(true)

      expect(described_class.build(user, convo)[:alpine]).to be_present
    end

    it "is nobody else's, however wet it is, in the facts or the seed" do
      allow(user).to receive(:me?).and_return(false)

      expect(described_class.build(user, convo)[:alpine]).to eq({})
      expect(Buddy::TodayBriefing.seed(user, convo)).not_to include("Alpine", "ALPINE")
    end
  end

  # Only days with rain during the plunge hours bring Alpine in at all.
  describe "Alpine for the owner" do
    before {
      allow(described_class).to receive(:alpine?).and_return(true)
      allow(Buddy::PlungeAdvisor).to receive_messages(briefing_lines: [], week_rain_lines: [])
    }

    it "leaves the key and its section out on a dry day" do
      expect(described_class.build(user, convo)[:alpine]).to eq({})
      expect(Buddy::TodayBriefing.seed(user, convo)).not_to include("ALPINE")
    end

    it "carries its rain hours into the seed on a wet one" do
      allow(Buddy::PlungeAdvisor).to receive_messages(
        briefing_lines:  ["Rain in the forecast", "Rain in Alpine 6pm-8pm"],
        week_rain_lines: [],
      )

      expect(Buddy::TodayBriefing.seed(user, convo)).to include("ALPINE", "Rain in Alpine 6pm-8pm")
    end
  end

  it "keeps the next two days coming up, and no more than a handful" do
    now  = tz.parse("2026-10-26 08:00") # a Monday
    item = ->(day, title) { { day: day, time: "6pm", title: title } }

    items = [item.call("tomorrow", "Dinner"), item.call("Wednesday", "Yoga"), item.call("Friday", "Party"), item.call("next Monday", "Trip")]
    expect(described_class.coming_up(user, items, now).pluck(:title)).to eq(%w[Dinner Yoga])

    many = Array.new(6) { |i| item.call("tomorrow", "Thing #{i}") }
    expect(described_class.coming_up(user, many, now).length).to eq(described_class::COMING_UP_LIMIT)
  end

  describe "the forecast table" do
    let(:now) { tz.parse("2026-10-26 08:00") }
    let(:days) {
      (0..6).map { |i| { date: Date.new(2026, 10, 26) + i, high: 60, low: 40, rain: 0, sky: "Clear", clouds: 0, notable: nil } }
    }

    before { allow(WeatherService).to receive(:week_days).and_return(days) }

    it "carries the week, with Alpine's rain on his" do
      allow(user).to receive(:me?).and_return(true)
      allow(Buddy::PlungeAdvisor).to receive(:forecast_cells).and_return({ Date.new(2026, 10, 28) => "80%" })

      rows = described_class.forecast(user, now)

      expect(rows.length).to eq(7)
      expect(rows[2][:alpine]).to eq("80%")
    end

    it "drops today once the day's high has stopped mattering" do
      rows = described_class.forecast(user, tz.parse("2026-10-26 18:00"))

      expect(rows.first[:date]).to eq(Date.new(2026, 10, 27))
    end

    it "leaves the seed only today's sky and the plunge call" do
      facts = {
        today:    [],
        due:      [],
        jobs:     [],
        week:     [],
        stash:    [],
        weather:  { high: 65, low: 41, notable: "rain", week: "rain Tue & Wed" },
        alpine:   { today: ["Rain in Alpine 1-3pm", "#{Buddy::PlungeAdvisor::PLUNGE_PREFIX} rain lands 1-3pm"], week: ["Wednesday, rain at 80%"] },
        forecast: days,
      }
      block = described_class.block(facts)

      expect(block).to include("WEATHER\n- Today: rain", Buddy::PlungeAdvisor::PLUNGE_PREFIX)
      expect(block).not_to include("High 65", "rain Tue", "1-3pm\n", "80%")
    end
  end

  describe "a question waiting on them" do
    let(:partner) { create(:user) }

    before {
      BuddyRelay.create!(
        from_user: partner, to_user: user, to_conversation: convo,
        kind: :ask_open, status: :delivered, body: "Are we still on for Thursday?"
      )
    }

    it "is collected and reaches the seed" do
      expect(described_class.build(user, convo)[:waiting].pluck(:question))
        .to include("Are we still on for Thursday?")
      expect(Buddy::TodayBriefing.seed(user, convo)).to include("Are we still on for Thursday?")
    end

    it "is left out once it was asked before yesterday" do
      BuddyRelay.create!(
        from_user: partner, to_user: user, to_conversation: convo, kind: :ask_open,
        status: :delivered, body: "Want me to close the garage?", delivered_at: 6.days.ago
      )

      questions = described_class.build(user, convo)[:waiting].pluck(:question)

      expect(questions).to include("Are we still on for Thursday?")
      expect(questions).not_to include("Want me to close the garage?")
    end
  end

  # A check-in speaks for itself when it fires; a briefing announcing it would
  # be announcing Buddy rather than the day.
  it "leaves a check-in scheduled for today out of the facts and the seed" do
    BuddyMemory.create!(
      user: user, kind: :followup, content: "Ask how the interview went.",
      check_in_at: 4.hours.from_now, relevant_at: 4.hours.from_now
    )

    facts = described_class.build(user, convo)

    expect(facts.values.flatten.map(&:to_s).join(" ")).not_to include("Ask how the interview went")
    expect(Buddy::TodayBriefing.seed(user, convo)).not_to include("interview went")
  end

  describe "what is on their mind" do
    let(:stash) {
      [
        { id: 1, category: "house", idea: "Repaint the shed", waiting: "9 days" },
        { id: 2, category: "work",  idea: "Write up the talk" },
      ]
    }

    # The guard reads the thought and the section renders it, and they have to
    # be looking at the same row.
    it "floats one idea with its age, the same row the guard reads, into the block", :aggregate_failures do
      many = (1..12).map { |n| { id: n, idea: "Idea #{n}", waiting: "#{n} days" } }

      expect(described_class.stash_lines({ stash: stash })).to eq(["Repaint the shed (9 days)"])
      expect(described_class.stash_lines({ stash: many }).length).to eq(1)
      expect(described_class.stash_floated({ stash: stash }).pluck(:idea)).to eq(["Repaint the shed"])

      block = described_class.block({ today: [], due: [], jobs: [], weather: nil, week: [], stash: stash })
      expect(block).to include("ON THEIR MIND", "- Repaint the shed (9 days)")
    end

    it "skips a blank row, and is empty when nothing is stashed" do
      rows = [{ id: 1, idea: "" }, { id: 2, idea: "Repaint the shed" }]

      expect(described_class.stash_lines({ stash: rows })).to eq(["Repaint the shed"])
      expect(described_class.stash_lines({ stash: [] })).to eq([])
      expect(described_class.block({ today: [], due: [], jobs: [], weather: nil, week: [], stash: [] }))
        .not_to include("ON THEIR MIND")
    end
  end

  # The count lives in Ruby, and so does the RARITY.
  describe "how often a thought is floated" do
    def stashed(idea, created:, surfaced: nil)
      memory = user.buddy_memories.create!(kind: :stash, content: idea, category: :home)
      memory.update_columns(created_at: created, surfaced_at: surfaced)
      memory
    end

    def hashes(rows)
      rows.map { |m| { id: m.id, idea: m.content, waiting: "7 weeks", category: "home" } }
    end

    def due(rows, now: Time.current) = described_class.stash_due(user, hashes(rows), now)

    it "rotates: the oldest unfloated first, nothing while one is warm, then the next, then round again" do
      [
        [nil, nil, :old],
        [1.day.ago, nil, :none],
        [4.days.ago, nil, :recent],
        [9.days.ago, 4.days.ago, :old],
      ].each { |old_surfaced, recent_surfaced, expected|
        BuddyMemory.where(user: user).delete_all
        old    = stashed("Kennel auto-open idea", created: 7.weeks.ago, surfaced: old_surfaced)
        recent = stashed("Glimmer iPad controls", created: 4.weeks.ago, surfaced: recent_surfaced)
        want   = { old: [old.id], recent: [recent.id], none: [] }[expected]

        expect(due([old, recent]).map { |i| i[:id] }).to eq(want), "#{old_surfaced.inspect}/#{recent_surfaced.inspect}"
      }
    end

    # `updated_at` is what the daily audit reads to tell an edit from an
    # untouched row, so a float must not look like one.
    it "stamps surfaced_at and leaves updated_at where it was" do
      row = stashed("Kennel auto-open idea", created: 7.weeks.ago)
      row.update_columns(updated_at: 3.days.ago)
      before = row.reload.updated_at

      described_class.mark_floated!(user, { id: row.id })

      expect(row.reload.surfaced_at).to be_present
      expect(row.reload.updated_at).to be_within(1.second).of(before)
      expect { described_class.mark_floated!(user, { idea: "No id" }) }.not_to raise_error
    end
  end

  describe "how a line reads" do
    # Whose it is goes in front; the calendar name never stands in for a place.
    it "puts whose it is in front, keeps the departure, and never names the calendar" do
      [
        [{ time: "4:00 PM", title: "Yoga", mine: false, owner: "Chelsea" }, "4:00 PM · Chelsea's Yoga"],
        [{ time: "9:00 AM", title: "Standup" }, "9:00 AM · Standup"],
        [
          { time: "11:40 AM", title: "Eye Follow Up", leave_by: "11:08 AM", drive_min: 22 },
          "11:40 AM · Eye Follow Up · leave by 11:08 AM (22 min drive)",
        ],
        [
          { time: "10:00 AM", title: "Hair trim", mine: false, owner: "Chelsea", cal: "Alchemibluum" },
          "10:00 AM · Chelsea's Hair trim",
        ],
        [{ time: "6:00 PM", title: "Salmon soyaki bowls", cal: "Ours 💕" }, "6:00 PM · Salmon soyaki bowls"],
      ].each { |item, expected| expect(described_class.agenda_line(item)).to eq(expected) }
    end

    # `2x` alone reads as a count, so the line says what it multiplies, including
    # on a job inside a group.
    it "says a group of jobs as the group, with each multiplier as points" do
      [
        [
          [
            { id: 1, name: "Gather trash", group: "trash" },
            { id: 2, name: "Take out trash bags", group: "trash" },
            { id: 3, name: "Replace Air Filter", hot: "5x" },
          ],
          ["trash: Gather trash, Take out trash bags", "Replace Air Filter · 5x points"],
        ],
        [
          [
            { id: 15, name: "Gather trash", group: "trash" },
            { id: 19, name: "Take trash cans out", group: "trash", hot: "2x" },
            { id: 17, name: "Take out trash bags", group: "trash" },
          ],
          ["trash: Gather trash, Take trash cans out · 2x points, Take out trash bags"],
        ],
        [[{ id: 1, name: "Go get mail", hot: "2x" }], ["Go get mail · 2x points"]],
        [[{ id: 1, name: "Go get mail" }], ["Go get mail"]],
      ].each { |rows, expected| expect(described_class.job_lines(rows)).to eq(expected) }
    end
  end

  # Everything that reaches this section is already today's, so the weekday is
  # the only part of a `Clock.day_at` stamp that tells them nothing.
  it "gives an ALSO DUE TODAY reminder its time without the day" do
    line = ->(fire_at) {
      described_class.block(
        today: [], due: [{ fire_at: fire_at, body: "Check the front flower bed." }],
        jobs: [], weather: nil, week: [], stash: []
      )
    }

    expect(line.call("Sat 7pm")).to include("- 7pm · Check the front flower bed.")
    expect(line.call("Mon 9:30am")).to include("- 9:30am · Check")
    expect(line.call("7pm")).to include("- 7pm · Check")
  end
end
