require "rails_helper"

RSpec.describe CronParse do
  # The end the person actually touches: a task whose cron is "sun:sunset-5m",
  # against an anchor they created from a Jil task rather than one Ruby knows.
  describe "one anchor" do
    let(:user) { create(:user) }
    let(:tz) { ActiveSupport::TimeZone[user.timezone] }
    let(:now) { tz.local(2026, 8, 19, 12, 0) }
    let(:tonight) { tz.local(2026, 8, 19, 20, 24) }
    let(:tomorrow) { tz.local(2026, 8, 20, 20, 23) }

    let!(:anchor) {
      user.anchors.create!(key: "sun:sunset").tap { |a|
        a.set_occurrence(tonight, identifier: "2026-08-19")
        a.set_occurrence(tomorrow, identifier: "2026-08-20")
      }
    }

    def task_with(cron)
      Task.create!(
        user: user, name: "Porch Lights", listener: "tell:porch", code: "// noop",
        enabled: true, cron: cron
      )
    end

    describe ".next" do
      it "still resolves an ordinary cron" do
        travel_to(now) { expect(described_class.next("0 6 * * *", user).in_time_zone(tz).hour).to eq(6) }
      end

      it "resolves an anchor expression" do
        travel_to(now) do
          expect(described_class.next("sun:sunset-5m", user)).to be_within(1.second).of(tonight - 5.minutes)
        end
      end

      # `|` already meant "whichever comes first"; anchors join that on equal
      # footing rather than getting their own field.
      it "takes the soonest across a mixed list" do
        travel_to(now) do
          expect(described_class.next("sun:sunset-5m | 0 6 * * *", user)).to(
            be_within(1.second).of(tonight - 5.minutes),
          )
        end
      end

      it "takes the cron when the cron is sooner" do
        travel_to(now) do
          expect(described_class.next("sun:sunset-5m | 30 12 * * *", user).in_time_zone(tz).hour).to eq(12)
        end
      end

      it "returns nil for junk, as before" do
        expect(described_class.next("not a cron", user)).to be_nil
      end

      it "returns nil for an anchor with nothing left on it" do
        anchor.occurrences.destroy_all

        travel_to(now) { expect(described_class.next("sun:sunset-5m", user)).to be_nil }
      end
    end

    describe ".anchors" do
      it "reports the keys a cron depends on" do
        expect(described_class.anchors("sun:sunset-5m | 0 6 * * *")).to eq(["sun:sunset"])
      end

      it "reports keys it has never heard of, since anchors are user data" do
        expect(described_class.anchors("trash:pickup-30m")).to eq(["trash:pickup"])
      end

      it "is empty for a plain cron" do
        expect(described_class.anchors("0 6 * * *")).to be_empty
        expect(described_class.anchors(nil)).to be_empty
      end

      it "dedupes repeats" do
        expect(described_class.anchors("sun:sunset-5m | sun:sunset+1h")).to eq(["sun:sunset"])
      end

      it "reports every distinct anchor in the string" do
        expect(described_class.anchors("sun:sunset-5m | trash:pickup-1h | 0 6 * * *")).to(
          eq(["sun:sunset", "trash:pickup"]),
        )
      end
    end

    # `|` already meant "whichever comes first". Anchors join that on equal
    # footing, so one task can hang off several of them at once.
    describe "several anchors on one task" do
      let!(:pickup) {
        user.anchors.create!(key: "trash:pickup").tap { |a|
          a.set_occurrence(tz.local(2026, 8, 19, 18, 0), identifier: "2026-08-19")
          a.set_occurrence(tz.local(2026, 8, 26, 18, 0), identifier: "2026-08-26")
        }
      }

      it "takes whichever comes first" do
        travel_to(now) do
          # pickup 18:00 beats sunset 20:24
          expect(described_class.next("sun:sunset-5m | trash:pickup-1h", user)).to(
            be_within(1.second).of(tz.local(2026, 8, 19, 17, 0)),
          )
        end
      end

      it "moves on to the other once the first has passed" do
        travel_to(tz.local(2026, 8, 19, 19, 0)) do
          expect(described_class.next("sun:sunset-5m | trash:pickup-1h", user)).to(
            be_within(1.second).of(tonight - 5.minutes),
          )
        end
      end

      it "re-resolves when either one moves" do
        task = travel_to(now) { task_with("sun:sunset-5m | trash:pickup-1h") }
        expect(task.next_trigger_at).to be_within(1.second).of(tz.local(2026, 8, 19, 17, 0))

        travel_to(now) { pickup.set_occurrence(tz.local(2026, 8, 19, 19, 30), identifier: "2026-08-19") }

        expect(task.reload.next_trigger_at).to be_within(1.second).of(tz.local(2026, 8, 19, 18, 30))
      end

      it "still validates with several anchors and a cron mixed in" do
        expect(
          user.tasks.build(
            name: "Mixed", listener: "tell:mixed", code: "// noop",
            cron: "sun:sunset-5m | trash:pickup-1h | 0 6 * * *"
          ),
        ).to be_valid
      end
    end

    describe "on a Task" do
      it "arms next_trigger_at from the anchor on save" do
        travel_to(now) { expect(task_with("sun:sunset-5m").next_trigger_at).to be_within(1.second).of(tonight - 5.minutes) }
      end

      # The re-arm that makes it recurring: Jil::Executor saves the task after
      # every run, and set_next_cron rolls it onto the next occurrence.
      it "re-arms to the next occurrence after it runs" do
        task = travel_to(now) { task_with("sun:sunset-5m") }

        travel_to(tz.local(2026, 8, 19, 20, 20)) do
          task.update!(last_trigger_at: Time.current)

          expect(task.next_trigger_at).to be_within(1.second).of(tomorrow - 5.minutes)
        end
      end

      it "is re-resolved when the anchor moves, without waiting for a run" do
        task = travel_to(now) { task_with("sun:sunset-5m") }
        expect(task.next_trigger_at).to be_within(1.second).of(tonight - 5.minutes)

        travel_to(now) { anchor.set_occurrence(tonight + 20.minutes, identifier: "2026-08-19") }

        expect(task.reload.next_trigger_at).to be_within(1.second).of(tonight + 15.minutes)
      end

      it "works the same for an anchor nobody wrote code for" do
        user.anchors.create!(key: "trash:pickup").set_occurrence(
          tz.local(2026, 8, 20, 7, 0), identifier: "2026-08-20"
        )

        travel_to(now) do
          expect(task_with("trash:pickup-30m").next_trigger_at).to(
            be_within(1.second).of(tz.local(2026, 8, 20, 6, 30)),
          )
        end
      end

      it "leaves tasks on other crons alone" do
        task = travel_to(now) { task_with("0 6 * * *") }
        was  = task.next_trigger_at

        anchor.set_occurrence(tonight + 20.minutes, identifier: "2026-08-19")

        expect(task.reload.next_trigger_at).to eq(was)
      end

      it "isn't fooled by a cron that merely mentions the domain" do
        task = travel_to(now) { task_with("0 6 * * *") }
        task.update_columns(cron: "0 6 * * * # sun:sunset in a comment")
        was = task.next_trigger_at

        anchor.set_occurrence(tonight + 20.minutes, identifier: "2026-08-19")

        expect(task.reload.next_trigger_at).to eq(was)
      end
    end
  end

  # When a task hangs off several anchors, moving ONE of them must never damage
  # what the others were scheduling. Every case here is "update anchor B, assert
  # the task is still correct about A" — the failure mode being guarded against is
  # a second anchor's update quietly knocking out the real next run.
  describe "several anchors on one task" do
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
end
