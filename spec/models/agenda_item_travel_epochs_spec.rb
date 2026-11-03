require "rails_helper"

# A travel epoch left behind by a previous placement of the item. Every reader
# formats these through Buddy::Clock, which prints a clock time and drops the
# date, so a stale one reads as a plausible time on the wrong day.
RSpec.describe AgendaItem do
  let(:user)     { create(:user) }
  let(:agenda)   { user.agendas.create!(name: "Personal") }
  let(:start_at) { Time.zone.parse("2026-09-15 14:45:00") }

  def item(travel)
    agenda.agenda_items.create!(
      name:     "Plunge with Wil",
      kind:     :event,
      start_at: start_at,
      end_at:   start_at + 1.hour,
      metadata: { "travel" => travel },
    )
  end

  # A departure from the day before and an arrival home from the same stale
  # placement, against a Tue 15 Sep event.
  it "refuses a day-stale stamp and falls back to arithmetic", :aggregate_failures do
    row = item({
      "leave_at"            => 1_789_418_975,
      "post_arrive_at"      => 1_789_428_394,
      "travel_seconds"      => 2757,
      "travel_minutes"      => 46,
      "post_travel_seconds" => 2794,
      "post_travel_minutes" => 47,
    })

    expect(row.leave_at).to be_nil
    expect(row.home_at).to eq(Time.zone.at(row.end_at.to_i + 2794))
    expect(Buddy::Context.send(:leave_by, row, user)).to be_nil
  end

  describe "an epoch that belongs to its event" do
    let(:good) {
      leave = (start_at - 51.minutes).to_i
      { "leave_at" => leave, "travel_seconds" => 2757, "post_travel_seconds" => 2794 }
    }

    # `now:` because `leave_by` also asks whether the departure is still ahead,
    # and the event itself is in the past.
    it "keeps it and reads it out" do
      row = item(good)

      expect(row.leave_at).to eq(Time.zone.at(good["leave_at"]))
      expect(Buddy::Context.send(:leave_by, row, user, now: start_at - 1.hour)).to be_present
    end
  end

  # A window of a whole day would let a day-stale stamp straight through.
  it "rejects a departure further ahead than any journey it plans" do
    row = item({ "leave_at" => (start_at - 13.hours).to_i, "travel_minutes" => 46 })

    expect(row.leave_at).to be_nil
  end

  it "keeps a genuinely long lead inside the bound" do
    row = item({ "leave_at" => (start_at - 11.hours).to_i, "travel_minutes" => 46 })

    expect(row.leave_at).to be_present
  end

  # The window is the 12h floor OR the drive itself, whichever is longer — so a
  # real cross-day drive (not a 46-min one 13h early) keeps its leave-by. A 14h
  # drive leaving 14h ahead is coherent; the stale case above stays rejected
  # because its drive was short.
  it "keeps a long lead when the drive itself is that long, and names the day it leaves" do
    drive = 14.hours.to_i
    row = item({ "leave_at" => (start_at - 14.hours).to_i, "travel_seconds" => drive })

    expect(row.leave_at).to eq(Time.zone.at(row.travel_hash["leave_at"]))

    said = Buddy::Context.send(:leave_by, row, user, now: start_at - 15.hours)
    expect(said).to eq(Buddy::Clock.day_at(row.leave_at, zone: user.timezone))
    expect(said).to match(/\A[A-Z][a-z]{2} /) # "Sun 12:45am"
  end

  # A departure AFTER the start is never right whatever the gap.
  it "rejects a departure after the thing has started" do
    row = item({ "leave_at" => (start_at + 4.minutes).to_i, "travel_minutes" => 46 })

    expect(row.leave_at).to be_nil
  end

  # An arrival home after midnight is ordinary, not stale — which is why the
  # check is a window around the event and not "the same calendar day".
  it "keeps a drive home that lands the next morning" do
    late = agenda.agenda_items.create!(
      name:     "Late one",
      kind:     :event,
      start_at: Time.zone.parse("2026-09-15 22:30:00"),
      end_at:   Time.zone.parse("2026-09-15 23:45:00"),
      metadata: {
        "travel" => { "post_arrive_at" => Time.zone.parse("2026-09-16 00:32:00").to_i },
      },
    )

    expect(late.home_at).to eq(Time.zone.parse("2026-09-16 00:32:00"))
  end

  # A task carries no `end_at`, so there is no window to judge an arrival
  # against and nothing for it to be wrong about. It keeps what it was given.
  it "leaves an item with nothing to check against alone" do
    row = agenda.agenda_items.create!(
      name:     "Someday",
      kind:     :task,
      start_at: start_at,
      end_at:   nil,
      metadata: { "travel" => { "post_arrive_at" => 1_789_418_975 } },
    )

    expect(row.home_at).to eq(Time.zone.at(1_789_418_975))
  end
end
