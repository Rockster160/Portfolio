require "rails_helper"

RSpec.describe FireDueAgendaTriggersWorker do
  let(:owner)  { create(:user) }
  let(:agenda) { create(:agenda, user: owner) }

  describe "#perform" do
    it "fires a past-due trigger and stamps fired_at (completed_at is user-only)" do
      item = create(:agenda_item, agenda: agenda, kind: :trigger,
        start_at: 1.minute.ago, trigger_expression: "morningRoutine")
      expect(::Jil).to receive(:trigger).with(
        owner, "morningRoutine", hash_including(:agenda_item),
        hash_including(auth: :agenda),
      )
      described_class.new.perform
      item.reload
      expect(item.fired_at).to be_present
      expect(item.completed_at).to be_nil
    end

    it "skips a trigger whose start_at is still in the future" do
      _item = create(:agenda_item, agenda: agenda, kind: :trigger,
        start_at: 5.minutes.from_now, trigger_expression: "later")
      expect(::Jil).not_to receive(:trigger)
      described_class.new.perform
    end

    it "skips a trigger that's already completed" do
      _item = create(:agenda_item, agenda: agenda, kind: :trigger,
        start_at: 1.minute.ago, completed_at: Time.current,
        trigger_expression: "done")
      expect(::Jil).not_to receive(:trigger)
      described_class.new.perform
    end
  end

  describe "rolling materialization of missed recurring triggers" do
    let(:user_zone) { ActiveSupport::TimeZone[owner.timezone] }

    it "materializes today's row when the schedule's save-time window has elapsed, then fires it" do
      schedule = nil
      # Save the schedule on May 11 9am — MATERIALIZE_WINDOW (30 hours)
      # has long expired by May 19, so the May 19 occurrence has no row from
      # the after_save hook and would never fire without the worker's backfill.
      Timecop.freeze(user_zone.local(2026, 5, 11, 9, 0, 0)) do
        schedule = create(:agenda_schedule, agenda: agenda, kind: :trigger,
          name: "Focus reminder", start_time: "07:00",
          recurrence: { "freq" => "daily" }, starts_on: Date.current,
          trigger_expression: "focusMode")
        # No row for May 19 exists yet — that's the gap the worker must close.
        expect(schedule.agenda_items.where(start_at: user_zone.local(2026, 5, 19).all_day))
          .to be_empty
      end

      Timecop.freeze(user_zone.local(2026, 5, 19, 7, 0, 30)) do
        allow(::Jil).to receive(:trigger)

        described_class.new.perform

        today_row = schedule.agenda_items
          .where(start_at: user_zone.local(2026, 5, 19, 7, 0, 0)).first
        expect(today_row).to be_present
        expect(today_row.fired_at).to be_present
        expect(today_row.completed_at).to be_nil
        expect(::Jil).to have_received(:trigger).with(
          owner, "focusMode", anything, hash_including(auth: :agenda),
        ).at_least(:once)
      end
    end

    it "does not double-create when the schedule already materialized today" do
      Timecop.freeze(user_zone.local(2026, 5, 19, 7, 0, 0)) do
        schedule = create(:agenda_schedule, agenda: agenda, kind: :trigger,
          name: "Focus", start_time: "10:00",
          recurrence: { "freq" => "daily" }, starts_on: Date.current,
          trigger_expression: "focusMode")
        expect { described_class.new.perform }
          .not_to change { schedule.agenda_items.count }
      end
    end

    it "doesn't materialize occurrences whose start time is older than the catchup window" do
      schedule = nil
      Timecop.freeze(user_zone.local(2026, 5, 11, 9, 0, 0)) do
        schedule = create(:agenda_schedule, agenda: agenda, kind: :trigger,
          name: "Old morning", start_time: "07:00",
          recurrence: { "freq" => "daily" }, starts_on: Date.current,
          trigger_expression: "morningRoutine")
      end

      # 10am — May 19 7am is 3 hours stale → no fresh materialization.
      Timecop.freeze(user_zone.local(2026, 5, 19, 10, 0, 0)) do
        allow(::Jil).to receive(:trigger)
        described_class.new.perform
        today_row_count = schedule.agenda_items
          .where(start_at: user_zone.local(2026, 5, 19).all_day).count
        expect(today_row_count).to eq(0)
      end
    end
  end
end
