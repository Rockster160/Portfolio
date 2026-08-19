require "rails_helper"

# The end the person actually touches: a task whose cron is "sun:sunset-5m",
# against an anchor they created from a Jil task rather than one Ruby knows.
RSpec.describe CronParse do
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
