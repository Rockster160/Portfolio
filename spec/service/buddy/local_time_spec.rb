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

    # This was already spelled out in prose - "take the hour from the local time
    # at the top of your prompt", plus a paragraph on how to read it - and the
    # 9am briefing still opened with "Good afternoon". A rule for deriving it
    # loses to one bad guess, so the answer is given instead of worked out.
    it "says morning, and which greeting, while UTC would read afternoon" do
      text = preamble_at(9)

      expect(text).to include("**Part of day:** morning")
      expect(text).to include(%("Good morning"))
      expect(text).to include("9:00 AM MDT")
    end

    it "carries the local hour, not the UTC one" do
      expect(preamble_at(9)).not_to include("3:00 PM")
    end

    it "turns over at noon and again in the evening" do
      expect(preamble_at(13)).to include("**Part of day:** afternoon")
      expect(preamble_at(18)).to include("**Part of day:** evening")
    end

    # "Good morning" at 2am is wrong and "Good evening" is wronger, so it gets
    # the one greeting that fits any hour.
    it "greets the small hours with a plain hey" do
      text = preamble_at(2)

      expect(text).to include("**Part of day:** late night")
      expect(text).to include(%("Hey"))
    end

    # The part of day and the perceived day turn over together: the moment
    # yesterday ends is the moment morning starts, so neither can drift from
    # the other by picking its own boundary.
    it "starts morning exactly when the day rolls over" do
      expect(preamble_at(Buddy::Day::ROLLOVER_HOUR - 1)).to include("late night")
      expect(preamble_at(Buddy::Day::ROLLOVER_HOUR)).to include("**Part of day:** morning")
    end

    it "covers every hour of the clock" do
      parts = (0..23).map { |h| preamble_at(h)[/\*\*Part of day:\*\* ([a-z ]+)\./, 1] }

      expect(parts).to all(be_present)
      expect(parts.uniq).to contain_exactly("morning", "afternoon", "evening", "late night")
    end
  end

  # The SCHEDULE is a morning thing; the briefing isn't. The chip sits in the
  # hero all day, so the seed can't assume which part of the day it's read in.
  describe "the Today briefing at any hour" do
    def seed_at(hour)
      Timecop.freeze(zone.local(2026, 8, 2, hour, 0)) { Buddy::TodayBriefing.seed(user) }
    end

    it "never tells it which part of the day it is" do
      [8, 14, 20].each { |hour|
        expect(seed_at(hour)).not_to match(/\b(good morning|this morning|fits the morning)\b/i)
      }
    end

    it "sends it to the part of day worked out from the clock instead" do
      expect(seed_at(20)).to include("Part of day")
    end

    it "says outright that it isn't a morning thing" do
      expect(seed_at(8)).to include("not a morning thing")
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
  end

  describe "resolving something they did \"today\"" do
    let(:ctx)   { Buddy::ToolContext.new(user) }
    let(:chore) { create(:chore, name: "8oz Water", created_by_user: user) }

    def completed!(at)
      create(:chore_completion, chore: chore, user: user, completed_at: at, day_key: at.to_date)
    end

    it "doesn't reach back into last night" do
      completed!(zone.local(2026, 8, 1, 20, 0))

      found = Timecop.freeze(morning) { ctx.resolve_chore_completions(chore, hint: :today) }

      expect(found).to be_empty
    end

    it "still finds one from this morning" do
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
    it "lasts to the end of their day, not to the end of UTC's" do
      expect(remember!(morning, "today")).to eq(zone.local(2026, 8, 3, 3, 0))
    end

    it "carries a day further for tomorrow" do
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
