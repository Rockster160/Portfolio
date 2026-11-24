require "rails_helper"

RSpec.describe UpdateActionStreak do
  let(:user) { create(:user) }

  def workout(at)
    user.action_events.create!(name: "Workout", timestamp: Time.zone.parse(at))
  end

  def walk_from(event)
    allow(described_class).to receive(:perform_async).and_call_original
    described_class.new.perform(event.id)
  end

  it "does nothing for an event that was removed before it ran" do
    gone = workout("2026-11-20 12:00")
    gone.destroy!

    expect { described_class.new.perform(gone.id) }.not_to raise_error
  end

  it "counts consecutive days, keeps a same-day repeat, and starts over after a gap" do
    events = ["2026-11-01 18:00", "2026-11-02 18:00", "2026-11-02 20:00", "2026-11-03 18:00", "2026-11-06 18:00"].map {
      workout(_1)
    }

    walk_from(events.first)

    expect(events.map { _1.reload.streak_length }).to eq([1, 2, 2, 3, 1])
  end

  # A backfill inserts events far behind the newest, and each one walked every
  # later event again whether or not anything had changed.
  it "stops walking at the first streak that comes out as it already was", :aggregate_failures do
    (1..20).each { |day|
      workout("2026-10-#{day.to_s.rjust(2, "0")} 18:00").update_columns(streak_length: day)
    }

    late = workout("2026-10-10 20:00")
    walk_from(late)

    expect(late.reload.streak_length).to eq(10)
    expect(described_class).to have_received(:perform_async).once
  end
end
