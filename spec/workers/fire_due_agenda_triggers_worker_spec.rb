require "rails_helper"

RSpec.describe FireDueAgendaTriggersWorker do
  let(:owner)  { create(:user) }
  let(:agenda) { create(:agenda, user: owner) }

  describe "#perform" do
    it "fires a past-due trigger and marks it completed" do
      item = create(:agenda_item, agenda: agenda, kind: :trigger,
        start_at: 1.minute.ago, trigger_expression: "morningRoutine")
      expect(::Jil).to receive(:trigger).with(
        owner, "morningRoutine", hash_including(:agenda_item),
        hash_including(auth: :agenda),
      )
      described_class.new.perform
      expect(item.reload.completed_at).to be_present
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

    it "materializes today's row when the schedule's 7-day window has elapsed, then fires it" do
      schedule = nil
      # Save the schedule "8 days ago" in the user's zone — its 7-day
      # materialization window stops at May 18 in the user's zone, so without
      # the backfill, May 19's occurrence has no row and never fires.
      Timecop.freeze(user_zone.local(2026, 5, 11, 9, 0, 0)) do
        schedule = create(:agenda_schedule, agenda: agenda, kind: :trigger,
          name: "Focus reminder", start_time: "07:00",
          recurrence: { "freq" => "daily" }, starts_on: Date.current,
          trigger_expression: "focusMode")
        expect(schedule.agenda_items.maximum(:start_at).in_time_zone(owner.timezone).to_date)
          .to be < Date.new(2026, 5, 19)
      end

      Timecop.freeze(user_zone.local(2026, 5, 19, 7, 0, 30)) do
        # Schedule also pre-materialized May 11..May 18 on save — they'll all
        # fire here too. We only care that the May 19 row gets created + fired.
        allow(::Jil).to receive(:trigger)

        described_class.new.perform

        today_row = schedule.agenda_items
          .where(start_at: user_zone.local(2026, 5, 19, 7, 0, 0)).first
        expect(today_row).to be_present
        expect(today_row.completed_at).to be_present
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
