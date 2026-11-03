require "rails_helper"

# The app runs with `config.time_zone = "UTC"` while everyone using it is on
# Mountain time, so anything that turns a DATE into a TIME without saying whose
# zone it means lands six hours out. That's a quiet failure: the query still
# works, it just answers about the wrong hours.
#
# Every example here fixes the clock to a moment where UTC and local disagree
# about which day or which half of the day it is — that gap IS the bug, and a
# test run at noon would pass either way.
RSpec.describe "Buddy and local time" do
  let(:user) { User.me }
  let(:zone) { ActiveSupport::TimeZone["America/Denver"] }

  # 9:23am Mountain is 3:23pm UTC: morning locally, afternoon in the zone the
  # process is running in. The exact shape of the reported bug.
  def morning
    zone.local(2026, 8, 2, 9, 23)
  end

  describe "the part of day it hands the model" do
    def preamble_at(hour)
      Timecop.freeze(zone.local(2026, 8, 2, hour, 0)) {
        Buddy::Personality.send(:time_preamble, user)
      }
    end

    # The band is derived from the clock and handed over as context. Morning
    # starts exactly when the perceived day rolls over, so neither can drift
    # from the other by picking its own boundary.
    it "hands the local part of day and hour, never UTC's, for every hour of the clock", :aggregate_failures do
      text = preamble_at(9)
      expect(text).to include("**Part of day:** morning")
      expect(text).to include("9am MDT")
      expect(text).not_to include("3:00 PM")

      expect(preamble_at(13)).to include("**Part of day:** afternoon")
      expect(preamble_at(18)).to include("**Part of day:** evening")
      expect(preamble_at(2)).to include("**Part of day:** late night")
      expect(preamble_at(Buddy::Day::ROLLOVER_HOUR - 1)).to include("late night")
      expect(preamble_at(Buddy::Day::ROLLOVER_HOUR)).to include("**Part of day:** morning")

      parts = (0..23).map { |h| preamble_at(h)[/\*\*Part of day:\*\* ([a-z ]+)\./, 1] }
      expect(parts).to all(be_present)
      expect(parts.uniq).to contain_exactly("morning", "afternoon", "evening", "late night")
    end
  end

  describe "which events count as today" do
    let!(:convo) { user.byte_conversations.create!(mode: :buddy) }

    def log!(at, name)
      ActionEvent.create!(user: user, name: name, timestamp: at)
    end

    # Date#beginning_of_day resolves in Time.zone (UTC), so "today" opened at
    # 6pm the previous evening and swept yesterday's tail into the briefing.
    it "starts the day in their zone, not six hours early" do
      log!(zone.local(2026, 8, 1, 20, 0), "yesterday evening")
      log!(zone.local(2026, 8, 2, 8, 0), "this morning")

      names = Timecop.freeze(morning) {
        Buddy::Context.build(user, convo)[:recent_events].pluck(:name)
      }

      expect(names).to include("this morning")
      expect(names).not_to include("yesterday evening")
    end

    it "keeps the whole day on a busy one, with each row's numbers" do
      first = log!(zone.local(2026, 8, 2, 6, 0), "Drink")
      first.update!(data: { Caffeine: 200 })
      30.times { |i| log!(zone.local(2026, 8, 2, 7, i), "Whisper") }

      rows = Timecop.freeze(morning + 1.hour) {
        Buddy::Context.build(user, convo)[:recent_events]
      }

      expect(rows.length).to eq(31)
      expect(rows.find { |row| row[:id] == first.id }[:data]).to eq("Caffeine 200")
    end
  end

  describe "resolving something they did \"today\"" do
    let(:ctx)   { Buddy::ToolContext.new(user) }
    let(:chore) { create(:chore, name: "8oz Water", created_by_user: user) }

    def completed!(at)
      create(:chore_completion, chore: chore, user: user, completed_at: at, day_key: at.to_date)
    end

    it "finds this morning's and doesn't reach back into last night" do
      completed!(zone.local(2026, 8, 1, 20, 0))
      done = completed!(zone.local(2026, 8, 2, 7, 30))

      found = Timecop.freeze(morning) { ctx.resolve_chore_completions(chore, hint: :today) }

      expect(found).to eq([done])
    end

    # The perceived day rolls at 3am, so something logged at 1am belongs to the
    # day before — the same rule the rest of Buddy uses.
    it "counts the small hours as the previous day" do
      completed!(zone.local(2026, 8, 2, 1, 0))

      found = Timecop.freeze(morning) { ctx.resolve_chore_completions(chore, hint: :yesterday) }

      expect(found.length).to eq(1)
    end
  end

  describe "a fact remembered only for today" do
    def remember!(at, phrase)
      Timecop.freeze(at) { Buddy::SideEffects.send(:apply_remember, user, "the plumber comes at 7", phrase) }
      BuddyMemory.where(user: user).order(:id).last.expires_at.in_time_zone(zone)
    end

    # Time.current.end_of_day is 23:59 UTC, which is 5:59pm locally — so a fact
    # meant to last the evening expired before the evening did. The day ends
    # when Buddy says it does (3am), not when the calendar does.
    it "lasts to the end of their day, not to the end of UTC's, and a day further for tomorrow", :aggregate_failures do
      expect(remember!(morning, "today")).to eq(zone.local(2026, 8, 3, 3, 0))
      expect(remember!(morning, "tomorrow")).to eq(zone.local(2026, 8, 4, 3, 0))
    end

    # Anchoring on local midnight would have expired this an hour before it was
    # written: at 1am the calendar has rolled but their day hasn't.
    it "doesn't expire in the past when they're up past midnight" do
      late = zone.local(2026, 8, 2, 1, 0)

      expect(remember!(late, "today")).to be > late
    end
  end
end
