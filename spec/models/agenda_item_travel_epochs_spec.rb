require "rails_helper"

# A travel epoch left behind by a previous placement.
#
# Prod 15 Sep, item 1081 "Plunge with Wil": a Tuesday 2:45 PM event whose whole
# travel hash was Monday's. Both briefings read it out as "leave by 2:49pm" —
# four minutes AFTER the thing began — because every reader formats these
# through Buddy::Clock, which prints a clock time and drops the date.
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

  # The real row, verbatim: leave_at is Mon 14 Sep 2:49 PM MDT and
  # post_arrive_at is Mon 14 Sep 5:26 PM MDT, against a Tue 15 Sep event.
  describe "the one that shipped" do
    let(:stale) {
      {
        "leave_at"            => 1_789_418_975,
        "post_arrive_at"      => 1_789_428_394,
        "travel_seconds"      => 2757,
        "travel_minutes"      => 46,
        "post_travel_seconds" => 2794,
        "post_travel_minutes" => 47,
      }
    }

    it "refuses a departure from the day before" do
      expect(item(stale).leave_at).to be_nil
    end

    # Not nil: `home_at` has always had arithmetic to fall back on, and an
    # incoherent stamp is treated as no stamp — which is a state it handles.
    it "computes the way home rather than trusting a stale arrival" do
      row = item(stale)

      expect(row.home_at).to eq(Time.zone.at(row.end_at.to_i + 2794))
    end

    # What the person actually reads. `leave_by` blank is what lets
    # briefing_facts fall through to the bare drive time.
    it "says nothing about a leave-by rather than saying the wrong one" do
      expect(Buddy::Context.send(:leave_by, item(stale), user)).to be_nil
    end
  end

  describe "an epoch that belongs to its event" do
    let(:good) {
      leave = (start_at - 51.minutes).to_i
      { "leave_at" => leave, "travel_seconds" => 2757, "post_travel_seconds" => 2794 }
    }

    it "keeps it" do
      expect(item(good).leave_at).to eq(Time.zone.at(good["leave_at"]))
    end

    it "reads it out" do
      expect(Buddy::Context.send(:leave_by, item(good), user)).to be_present
    end
  end

  # The bound is what catches a day-stale stamp, and 23 hours is what the real
  # one was — so a window of a whole day would have let it straight through.
  it "rejects a departure further ahead than any journey it plans" do
    row = item({ "leave_at" => (start_at - 13.hours).to_i, "travel_minutes" => 46 })

    expect(row.leave_at).to be_nil
  end

  it "keeps a genuinely long lead inside the bound" do
    row = item({ "leave_at" => (start_at - 11.hours).to_i, "travel_minutes" => 46 })

    expect(row.leave_at).to be_present
  end

  # A departure AFTER the start is the shape that shipped, and it is never
  # right whatever the gap.
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
