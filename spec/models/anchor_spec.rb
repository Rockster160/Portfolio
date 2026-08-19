require "rails_helper"

RSpec.describe Anchor do
  let(:user) { create(:user) }
  let(:tz) { ActiveSupport::TimeZone[user.timezone] }
  let(:now) { tz.local(2026, 8, 19, 12, 0) }

  def anchor_for(key="sun:sunset")
    user.anchors.create!(key: key)
  end

  describe "the key" do
    it "normalizes case and whitespace" do
      expect(anchor_for("  SUN:Sunset ").key).to eq("sun:sunset")
    end

    it "is unique per user" do
      anchor_for
      expect(user.anchors.build(key: "sun:sunset")).not_to be_valid
    end

    it "is free for another user to use" do
      anchor_for
      expect(create(:user).anchors.build(key: "sun:sunset")).to be_valid
    end

    it "must look like domain:event" do
      expect(user.anchors.build(key: "sunset")).not_to be_valid
      expect(user.anchors.build(key: "trash:pickup")).to be_valid
    end
  end

  describe "#set_occurrence" do
    let(:anchor) { anchor_for }

    it "appends when no identifier is given" do
      anchor.set_occurrence(now + 1.hour)
      anchor.set_occurrence(now + 2.hours)

      expect(anchor.occurrences.count).to eq(2)
    end

    # The property that makes an hourly refresh safe to run forever.
    it "replaces in place when the identifier repeats" do
      anchor.set_occurrence(now + 1.hour, identifier: "2026-08-19")
      anchor.set_occurrence(now + 90.minutes, identifier: "2026-08-19")

      expect(anchor.occurrences.count).to eq(1)
      expect(anchor.occurrences.sole.occurs_at).to be_within(1.second).of(now + 90.minutes)
    end

    it "keeps different identifiers apart" do
      anchor.set_occurrence(now + 1.hour, identifier: "2026-08-19")
      anchor.set_occurrence(now + 25.hours, identifier: "2026-08-20")

      expect(anchor.occurrences.count).to eq(2)
    end
  end

  describe "#remove_occurrence" do
    it "drops that one and leaves the anchor" do
      anchor = anchor_for
      anchor.set_occurrence(now + 1.hour, identifier: "a")
      anchor.set_occurrence(now + 2.hours, identifier: "b")

      anchor.remove_occurrence("a")

      expect(anchor.occurrences.pluck(:identifier)).to eq(["b"])
      expect(described_class.for(user, "sun:sunset")).to be_present
    end
  end

  describe ".resolve" do
    let!(:anchor) { anchor_for }

    before do
      anchor.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "2026-08-19")
      anchor.set_occurrence(tz.local(2026, 8, 20, 20, 23), identifier: "2026-08-20")
    end

    it "returns the next occurrence" do
      expect(described_class.resolve("sun:sunset", user: user, after: now)).to(
        be_within(1.second).of(tz.local(2026, 8, 19, 20, 24)),
      )
    end

    it "applies the offset" do
      expect(described_class.resolve("sun:sunset-5m", user: user, after: now)).to(
        be_within(1.second).of(tz.local(2026, 8, 19, 20, 19)),
      )
    end

    # The offset shifts what counts as "still ahead" — at 20:21 tonight's
    # sunset is still coming, but "5 minutes before" it already went by.
    it "skips an occurrence whose offset time has passed" do
      after = tz.local(2026, 8, 19, 20, 21)

      expect(described_class.resolve("sun:sunset-5m", user: user, after: after)).to(
        be_within(1.second).of(tz.local(2026, 8, 20, 20, 18)),
      )
    end

    # A task re-resolves the instant it fires. If resolution were inclusive it
    # would hand back the occurrence just consumed, leaving next_trigger_at
    # equal to now — JilRunnerWorker finds it pending again and loops.
    it "never returns the moment it was asked about" do
      fired = tz.local(2026, 8, 19, 20, 24)

      expect(described_class.resolve("sun:sunset", user: user, after: fired)).to(
        be_within(1.second).of(tz.local(2026, 8, 20, 20, 23)),
      )
    end

    it "never returns the moment it was asked about, with a positive offset" do
      # sun:sunset+1h fires at 21:24; re-resolving there must not re-offer it.
      fired = tz.local(2026, 8, 19, 21, 24)

      expect(described_class.resolve("sun:sunset+1h", user: user, after: fired)).to(
        be_within(1.second).of(tz.local(2026, 8, 20, 21, 23)),
      )
    end

    it "is always strictly ahead, whatever the offset" do
      ["sun:sunset", "sun:sunset-5m", "sun:sunset+1h"].each do |expression|
        [now, tz.local(2026, 8, 19, 20, 19), tz.local(2026, 8, 19, 20, 24)].each do |after|
          at = described_class.resolve(expression, user: user, after: after)
          expect(at).to be > after, "#{expression} from #{after} returned #{at}"
        end
      end
    end

    describe "pinned to one identifier" do
      it "resolves that occurrence and no other" do
        expect(described_class.resolve("sun:sunset[2026-08-20]", user: user, after: now)).to(
          be_within(1.second).of(tz.local(2026, 8, 20, 20, 23)),
        )
      end

      it "applies the offset to it" do
        expect(described_class.resolve("sun:sunset[2026-08-20]-5m", user: user, after: now)).to(
          be_within(1.second).of(tz.local(2026, 8, 20, 20, 18)),
        )
      end

      # A pinned expression is a one-shot by design: once that occurrence is
      # past there is no next one, and it stops resolving.
      it "stops resolving once its own occurrence has gone by" do
        after = tz.local(2026, 8, 21, 12, 0)

        expect(described_class.resolve("sun:sunset[2026-08-20]", user: user, after: after)).to be_nil
      end

      it "returns nil for an identifier that isn't there" do
        expect(described_class.resolve("sun:sunset[1999-01-01]", user: user, after: now)).to be_nil
      end

      it "doesn't hop to a different occurrence the way the unpinned form does" do
        after = tz.local(2026, 8, 19, 20, 30) # tonight's already gone

        expect(described_class.resolve("sun:sunset[2026-08-19]", user: user, after: after)).to be_nil
        expect(described_class.resolve("sun:sunset", user: user, after: after)).to be_present
      end
    end

    it "returns nil once it runs out of occurrences" do
      expect(described_class.resolve("sun:sunset", user: user, after: tz.local(2026, 9, 1))).to be_nil
    end

    it "returns nil for an anchor that doesn't exist" do
      expect(described_class.resolve("moon:rise", user: user, after: now)).to be_nil
    end

    it "returns nil for a non-expression" do
      expect(described_class.resolve("0 6 * * *", user: user, after: now)).to be_nil
    end

    it "doesn't reach across users" do
      expect(described_class.resolve("sun:sunset", user: create(:user), after: now)).to be_nil
    end
  end

  # Retention is COUNTED, not aged: an anchor may be hourly, daily or weekly,
  # and any fixed duration would be far too long for one and too short for
  # another. Keeping the last N spans N of that anchor's own intervals.
  describe "#prune!" do
    let(:anchor) { anchor_for }

    def past_occurrences(count)
      travel_to(now) do
        count.times { |i| anchor.set_occurrence(now - (i + 1).hours, identifier: "past-#{i}") }
      end
    end

    it "keeps everything while under the limit" do
      past_occurrences(described_class::KEEP_PAST)

      expect(anchor.occurrences.reload.count).to eq(described_class::KEEP_PAST)
    end

    it "keeps only the most recent past ones beyond it" do
      past_occurrences(described_class::KEEP_PAST + 5)

      kept = anchor.occurrences.reload.pluck(:identifier)
      expect(kept.count).to eq(described_class::KEEP_PAST)
      expect(kept).to include("past-0", "past-9")
      expect(kept).not_to include("past-10", "past-14")
    end

    it "never drops future occurrences" do
      past_occurrences(described_class::KEEP_PAST + 5)
      travel_to(now) { anchor.set_occurrence(now + 1.hour, identifier: "upcoming") }

      expect(anchor.occurrences.reload.pluck(:identifier)).to include("upcoming")
    end

    # A positive offset fires AFTER the moment, so a trigger can still be
    # pending against an occurrence that has already gone by.
    it "does not drop one a pending trigger is still bound to" do
      travel_to(now) { anchor.set_occurrence(now - 100.hours, identifier: "ancient") }
      ancient = anchor.occurrences.find_by(identifier: "ancient")
      user.scheduled_triggers.create!(
        trigger: :late, name: :"late-one", anchor_occurrence: ancient,
        offset_seconds: 3_600, execute_at: ancient.occurs_at + 1.hour, data: {}
      )

      past_occurrences(described_class::KEEP_PAST + 5)

      expect(anchor.occurrences.reload.pluck(:identifier)).to include("ancient")
    end
  end

  describe "#propagate!" do
    let(:anchor) { anchor_for }

    before { allow(Jil::Schedule).to receive(:update) }

    def anchored_trigger(occurrence, offset: -300)
      user.scheduled_triggers.create!(
        trigger: :lights, name: :"porch-lights", anchor_occurrence: occurrence,
        offset_seconds: offset, execute_at: occurrence.occurs_at + offset, data: {}
      )
    end

    it "moves a pending trigger onto the new time" do
      occurrence = anchor.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "2026-08-19")
      trigger = anchored_trigger(occurrence)

      anchor.set_occurrence(tz.local(2026, 8, 19, 20, 40), identifier: "2026-08-19")

      expect(trigger.reload.execute_at).to be_within(1.second).of(tz.local(2026, 8, 19, 20, 35))
    end

    # The reason the trigger points at an occurrence rather than at the anchor:
    # a weekly anchor moving three days is still the same occurrence, and an
    # hourly one moving ten minutes must not be confused with the next.
    it "follows its own occurrence however far it moves" do
      occurrence = anchor.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "wk")
      trigger = anchored_trigger(occurrence)

      anchor.set_occurrence(tz.local(2026, 8, 22, 20, 24), identifier: "wk")

      expect(trigger.reload.execute_at).to be_within(1.second).of(tz.local(2026, 8, 22, 20, 19))
    end

    it "is unmoved by a different occurrence on the same anchor" do
      occurrence = anchor.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "a")
      trigger = anchored_trigger(occurrence)

      anchor.set_occurrence(tz.local(2026, 8, 20, 20, 23), identifier: "b")

      expect(trigger.reload.execute_at).to be_within(1.second).of(tz.local(2026, 8, 19, 20, 19))
    end

    it "goes away with the occurrence it was bound to" do
      occurrence = anchor.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "a")
      trigger = anchored_trigger(occurrence)

      occurrence.destroy

      expect(ScheduledTrigger.find_by(id: trigger.id)).to be_nil
    end

    it "reschedules the sidekiq job for what it moved" do
      occurrence = anchor.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "2026-08-19")
      trigger = anchored_trigger(occurrence)

      anchor.set_occurrence(tz.local(2026, 8, 19, 20, 40), identifier: "2026-08-19")

      expect(Jil::Schedule).to have_received(:update).with(having_attributes(id: trigger.id))
    end

    it "leaves already-started triggers alone" do
      occurrence = anchor.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "2026-08-19")
      trigger = anchored_trigger(occurrence)
      trigger.update_columns(started_at: Time.current)

      anchor.set_occurrence(tz.local(2026, 8, 19, 20, 40), identifier: "2026-08-19")

      expect(trigger.reload.execute_at).to be_within(1.second).of(tz.local(2026, 8, 19, 20, 19))
    end

    it "leaves triggers on other anchors alone" do
      sunrise = user.anchors.create!(key: "sun:sunrise")
      elsewhere = sunrise.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "a")
      other = user.scheduled_triggers.create!(
        trigger: :wake, name: :"wake-up", anchor_occurrence: elsewhere,
        offset_seconds: 0, execute_at: elsewhere.occurs_at, data: {}
      )

      anchor.set_occurrence(tz.local(2026, 8, 19, 20, 40), identifier: "2026-08-19")

      expect(other.reload.execute_at).to be_within(1.second).of(tz.local(2026, 8, 19, 20, 24))
    end

    it "settles rather than churning when the same time is restated" do
      occurrence = anchor.set_occurrence(tz.local(2026, 8, 19, 20, 24), identifier: "2026-08-19")
      anchored_trigger(occurrence)

      anchor.set_occurrence(tz.local(2026, 8, 19, 20, 40), identifier: "2026-08-19")
      anchor.set_occurrence(tz.local(2026, 8, 19, 20, 40), identifier: "2026-08-19")

      expect(Jil::Schedule).to have_received(:update).once
    end
  end
end
