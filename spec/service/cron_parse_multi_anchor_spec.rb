require "rails_helper"

# When a task hangs off several anchors, moving ONE of them must never damage
# what the others were scheduling. Every case here is "update anchor B, assert
# the task is still correct about A" — the failure mode being guarded against is
# a second anchor's update quietly knocking out the real next run.
RSpec.describe "CronParse: several anchors on one task" do
  let(:user) { create(:user) }
  let(:tz) { ActiveSupport::TimeZone[user.timezone] }
  let(:now) { tz.local(2026, 8, 19, 12, 0) }
  let(:cron) { "sun:sunset-5m | trash:pickup-1h" }

  # sunset 20:24 → task at 20:19
  let!(:sunset) {
    user.anchors.create!(key: "sun:sunset").tap { |a|
      a.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "d1")
      a.set_occurrence(tz.local(2026, 8, 20, 20, 23), identifier: "d2")
    }
  }

  # pickup 18:00 → task at 17:00, so pickup is the soonest to start with
  let!(:pickup) {
    user.anchors.create!(key: "trash:pickup").tap { |a|
      a.set_occurrence(tz.local(2026, 8, 19, 18, 0), identifier: "w1")
      a.set_occurrence(tz.local(2026, 8, 26, 18, 0), identifier: "w2")
    }
  }

  let!(:task) {
    travel_to(now) do
      user.tasks.create!(
        name: "Multi", listener: "tell:multi", code: "// noop", enabled: true, cron: cron,
      )
    end
  }

  def described_class_next
    CronParse.next(cron, user)
  end

  def next_run
    task.reload.next_trigger_at
  end

  def move(anchor, identifier, to)
    travel_to(now) { anchor.set_occurrence(to, identifier: identifier) }
  end

  it "starts on the soonest of the two" do
    expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 17, 0))
  end

  describe "moving the anchor that is NOT currently soonest" do
    it "later — the soonest one is untouched" do
      move(sunset, "d1", tz.local(2026, 8, 19, 22, 0))

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 17, 0))
    end

    it "earlier but still second — the soonest one is untouched" do
      move(sunset, "d1", tz.local(2026, 8, 19, 19, 0))

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 17, 0))
    end

    it "earlier than the other — it takes over" do
      move(sunset, "d1", tz.local(2026, 8, 19, 16, 0))

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 15, 55))
    end
  end

  describe "moving the anchor that IS currently soonest" do
    it "earlier — it stays soonest" do
      move(pickup, "w1", tz.local(2026, 8, 19, 15, 0))

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 14, 0))
    end

    it "later but still soonest — it follows" do
      move(pickup, "w1", tz.local(2026, 8, 19, 19, 0))

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 18, 0))
    end

    # The handover: pushing the leader past the other must promote the other,
    # not leave the task pointed at a time nothing happens.
    it "past the other — the other takes over" do
      move(pickup, "w1", tz.local(2026, 8, 19, 23, 0))

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 20, 19))
    end
  end

  describe "one anchor going quiet" do
    it "clearing it leaves the other still scheduling" do
      travel_to(now) { pickup.occurrences.destroy_all }

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 20, 19))
    end

    it "destroying it leaves the other still scheduling" do
      travel_to(now) { pickup.destroy }
      travel_to(now) { sunset.set_occurrence(tz.local(2026, 8, 19, 20, 30), identifier: "d1") }

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 20, 25))
    end

    # An anchor that resolves to nothing must drop out of the list rather than
    # nil the whole expression.
    it "an empty anchor doesn't nil out the one that still works" do
      travel_to(now) { sunset.occurrences.destroy_all }

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 17, 0))
    end

    it "both empty is the only way it goes blank" do
      travel_to(now) do
        sunset.occurrences.destroy_all
        pickup.occurrences.destroy_all
      end

      expect(next_run).to be_nil
    end

    it "and it recovers the moment either is fed again" do
      travel_to(now) do
        sunset.occurrences.destroy_all
        pickup.occurrences.destroy_all
      end
      expect(next_run).to be_nil

      move(pickup, "w1", tz.local(2026, 8, 19, 16, 0))

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 15, 0))
    end
  end

  # Regression: the NoMethodError rescue used to wrap the whole expression, so
  # ONE piece failing to resolve nilled every other piece too — a single bad
  # anchor stopped the task dead even though the others were fine.
  describe "when one piece fails to resolve" do
    before do
      allow(Anchor).to receive(:resolve).and_call_original
      allow(Anchor).to receive(:resolve).with("sun:sunset-5m", anything) { raise NoMethodError, "boom" }
    end

    it "drops that piece and still schedules off the others" do
      travel_to(now) do
        expect(described_class_next).to be_within(1.second).of(tz.local(2026, 8, 19, 17, 0))
      end
    end

    it "leaves a plain cron in the same expression working" do
      travel_to(now) do
        expect(CronParse.next("sun:sunset-5m | 30 13 * * *", user)).to(
          be_within(1.second).of(tz.local(2026, 8, 19, 13, 30)),
        )
      end
    end

    it "only goes nil when nothing at all resolves" do
      travel_to(now) { expect(CronParse.next("sun:sunset-5m", user)).to be_nil }
    end
  end

  describe "with a plain cron in the mix" do
    let(:cron) { "sun:sunset-5m | trash:pickup-1h | 30 13 * * *" }

    it "the cron can win" do
      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 13, 30))
    end

    it "moving an anchor doesn't disturb the cron's claim" do
      move(sunset, "d1", tz.local(2026, 8, 19, 22, 0))

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 13, 30))
    end

    it "the cron still answers when every anchor is empty" do
      travel_to(now) do
        sunset.occurrences.destroy_all
        pickup.occurrences.destroy_all
      end

      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 13, 30))
    end
  end

  # A cron may name an anchor that doesn't exist yet — the task can be the
  # placeholder and the feeder can come later. It saves, warns, and schedules
  # off whichever anchors ARE ready in the meantime.
  describe "naming an anchor that doesn't exist yet" do
    let(:placeholder) {
      travel_to(now) do
        user.tasks.create!(
          name: "Premature", listener: "tell:pre", code: "// noop", enabled: true,
          cron: "trash:pickup-1h | school:bell-15m"
        )
      end
    }

    it "saves, and warns about the one that's missing" do
      expect(placeholder.cron_warnings.join).to include("school:bell", "doesn't exist yet")
    end

    it "still schedules off the anchor that is ready" do
      expect(placeholder.next_trigger_at).to be_within(1.second).of(tz.local(2026, 8, 19, 17, 0))
    end

    it "picks the new anchor up once it exists, with no edit to the task" do
      placeholder

      travel_to(now) do
        user.anchors.create!(key: "school:bell").set_occurrence(
          tz.local(2026, 8, 19, 15, 0), identifier: "b1"
        )
      end

      expect(placeholder.reload.next_trigger_at).to(
        be_within(1.second).of(tz.local(2026, 8, 19, 14, 45)),
      )
      expect(placeholder.cron_warnings).to be_empty
    end
  end

  describe "three anchors" do
    let(:cron) { "sun:sunset-5m | trash:pickup-1h | school:bell-15m" }
    # Not `let!` — the task has to be created AFTER this exists, and the outer
    # `let!(:task)` hook runs first. Forcing it from `task` gets the order right.
    let(:bell) {
      user.anchors.create!(key: "school:bell").tap { |a|
        a.set_occurrence(tz.local(2026, 8, 19, 15, 0), identifier: "b1")
      }
    }
    let!(:task) {
      bell
      travel_to(now) do
        user.tasks.create!(
          name: "Multi", listener: "tell:multi", code: "// noop", enabled: true, cron: cron,
        )
      end
    }

    it "picks the soonest of all three" do
      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 14, 45))
    end

    it "hands off correctly as the leader is pushed back" do
      move(bell, "b1", tz.local(2026, 8, 19, 23, 0))
      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 17, 0))

      move(pickup, "w1", tz.local(2026, 8, 19, 23, 30))
      expect(next_run).to be_within(1.second).of(tz.local(2026, 8, 19, 20, 19))
    end

    it "each one independently re-resolves the whole expression" do
      [sunset, pickup, bell].each do |anchor|
        expect { travel_to(now) { anchor.touch } }.not_to(change { next_run })
      end
    end
  end
end
