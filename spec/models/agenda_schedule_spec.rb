# == Schema Information
#
# Table name: agenda_schedules
#
#  id                   :bigint           not null, primary key
#  agenda_id            :bigint           not null
#  name                 :string           not null
#  kind                 :integer          not null
#  start_time           :time             not null
#  duration_minutes     :integer
#  starts_on            :date             not null
#  until_on             :date
#  recurrence           :jsonb            not null
#  notes                :text
#  location             :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  color                :string
#  trigger_expression   :text
#  occurrence_count     :integer
#  external_uid         :text
#  external_etag        :text
#  external_updated_at  :datetime
#  all_day              :boolean          default(FALSE), not null
#  metadata             :jsonb            not null
#  arrive_early_minutes :integer          default(0), not null
#  travel_nav_address   :string
#

require "rails_helper"

RSpec.describe AgendaSchedule do
  describe "the model" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }

    def build_schedule(**overrides)
      create(:agenda_schedule, { agenda: agenda }.merge(overrides))
    end

    it "requires a duration for an event, not for a task" do
      expect(build(:agenda_schedule, agenda: agenda, kind: "event", duration_minutes: nil)).not_to be_valid
      expect(build(:agenda_schedule, agenda: agenda, kind: "task", duration_minutes: nil)).to be_valid
    end

    describe "#matches?" do
      def expect_matches(recurrence, starts_on, dates)
        sched = build_schedule(recurrence: recurrence, starts_on: starts_on)
        dates.each do |date, want|
          expect(sched.matches?(date)).to eq(want), "#{recurrence.inspect} on #{date}"
        end
      end

      it "matches the fixed frequencies from starts_on, until until_on", :aggregate_failures do
        may1 = Date.new(2026, 5, 1)
        expect_matches({ "freq" => "daily" }, may1,
          Date.new(2026, 5, 1) => true, Date.new(2026, 5, 15) => true, Date.new(2026, 4, 30) => false)
        bounded = build_schedule(recurrence: { "freq" => "daily" }, starts_on: may1, until_on: Date.new(2026, 5, 5))
        expect(bounded.matches?(Date.new(2026, 5, 6))).to be false
        expect_matches({ "freq" => "weekdays" }, may1, Date.new(2026, 5, 4) => true, Date.new(2026, 5, 9) => false)
        expect_matches({ "freq" => "weekly", "by_day" => %w[mon wed fri] }, may1,
          Date.new(2026, 5, 4) => true, Date.new(2026, 5, 5) => false)
        expect_matches({ "freq" => "monthly", "by_month_day" => [1, 15] }, may1,
          Date.new(2026, 5, 15) => true, Date.new(2026, 5, 20) => false)
        expect_matches({ "freq" => "custom", "interval" => 3, "unit" => "day" }, may1,
          Date.new(2026, 5, 4) => true, Date.new(2026, 5, 5) => false)
        expect_matches({ "freq" => "yearly" }, Date.new(2026, 6, 15),
          Date.new(2026, 6, 15) => true, Date.new(2027, 6, 15) => true, Date.new(2100, 6, 15) => true,
          Date.new(2026, 6, 14) => false, Date.new(2026, 7, 15) => false, Date.new(2025, 6, 15) => false)
      end

      it "matches the Nth or last weekday of a month, every N months", :aggregate_failures do
        # Every third Tuesday.
        expect_matches({ "freq" => "monthly", "by_set_pos" => 3, "by_day" => ["tue"] }, Date.new(2026, 5, 19),
          Date.new(2026, 5, 19) => true, Date.new(2026, 6, 16) => true,
          Date.new(2026, 5, 12) => false, Date.new(2026, 5, 20) => false)
        # Every second Thursday.
        expect_matches(
          { "freq" => "custom", "interval" => 1, "unit" => "month", "by_set_pos" => 2, "by_day" => ["thu"] },
          Date.new(2026, 5, 14),
          Date.new(2026, 5, 14) => true, Date.new(2026, 6, 11) => true, Date.new(2026, 5, 7) => false,
          Date.new(2026, 5, 21) => false, Date.new(2026, 5, 15) => false,
        )
        # Every last Friday.
        expect_matches(
          { "freq" => "custom", "interval" => 1, "unit" => "month", "by_set_pos" => -1, "by_day" => ["fri"] },
          Date.new(2026, 5, 29),
          Date.new(2026, 5, 29) => true, Date.new(2026, 6, 26) => true, Date.new(2026, 5, 22) => false,
        )
        # Third Tuesday, quarterly.
        expect_matches(
          { "freq" => "custom", "interval" => 3, "unit" => "month", "by_set_pos" => 3, "by_day" => ["tue"] },
          Date.new(2026, 1, 20),
          Date.new(2026, 1, 20) => true, Date.new(2026, 4, 21) => true, Date.new(2026, 7, 21) => true,
          Date.new(2026, 2, 17) => false, Date.new(2026, 6, 20) => false, Date.new(2026, 4, 14) => false,
        )
        # The 15th, every other month.
        expect_matches(
          { "freq" => "custom", "interval" => 2, "unit" => "month", "by_month_day" => [15] },
          Date.new(2026, 1, 15),
          Date.new(2026, 1, 15) => true, Date.new(2026, 3, 15) => true,
          Date.new(2026, 2, 15) => false, Date.new(2026, 3, 14) => false,
        )
      end
    end

    describe "#phantom_for" do
      let(:sched) {
        build_schedule(
          kind:             "event",
          start_time:       "09:30",
          duration_minutes: 60,
          recurrence:       { "freq" => "weekdays" },
          starts_on:        Date.new(2026, 5, 4),
        )
      }

      it "returns an unsaved AgendaItem on a matching date" do
        item = sched.phantom_for(Date.new(2026, 5, 4))
        expect(item).to be_an(AgendaItem)
        expect(item).not_to be_persisted
        expect(item).to be_phantom
        expect(item.kind).to eq("event")
        expect((item.end_at - item.start_at).to_i).to eq(3600)
      end

      it "returns nil on a non-matching, excluded or already-materialized date" do
        expect(sched.phantom_for(Date.new(2026, 5, 9))).to be_nil

        sched.add_excluded_date!(Date.new(2026, 5, 4))
        expect(sched.excluded?(Date.new(2026, 5, 4))).to be true
        expect(sched.phantom_for(Date.new(2026, 5, 4))).to be_nil

        sched.agenda_items.create!(
          agenda:   agenda,
          kind:     "event",
          name:     "Materialized",
          start_at: sched.send(:occurrence_start_at, Date.new(2026, 5, 5)),
          end_at:   sched.send(:occurrence_end_at, Date.new(2026, 5, 5)),
        )
        expect(sched.phantom_for(Date.new(2026, 5, 5))).to be_nil
      end

      it "produces phantoms 100 years out without any persistence" do
        # starts_on is pushed past the materialize window so the after_save
        # hook doesn't persist any near-future occurrence — this test is
        # only asserting that phantom_for itself doesn't persist.
        sched = build_schedule(recurrence: { "freq" => "daily" }, starts_on: Date.current + 7)
        far_future = Date.current + 100.years
        item = sched.phantom_for(far_future)
        expect(item).to be_an(AgendaItem)
        expect(item).to be_phantom
        expect(item.start_at.to_date).to eq(far_future)
        expect(AgendaItem.count).to eq(0)
      end
    end

    # A series move that leaves its rows behind puts them back on the old
    # calendar the moment anything re-reads them.
    describe "moving a series between calendars" do
      let(:other) { create(:agenda, user: user, name: "Ours 💕") }

      def filed_under(schedule)
        AgendaItem.where(agenda_schedule_id: schedule.id).distinct.pluck(:agenda_id)
      end

      it "takes its occurrences with it, and back again when the move is reverted" do
        schedule = build_schedule
        expect(filed_under(schedule)).to eq([agenda.id])

        schedule.update!(agenda: other)
        expect(filed_under(schedule)).to eq([other.id])

        schedule.update!(agenda: agenda)
        expect(filed_under(schedule)).to eq([agenda.id])
      end

      it "leaves them alone for an edit that isn't a move" do
        schedule = build_schedule
        expect { schedule.update!(name: "Renamed") }.not_to change { filed_under(schedule) }
      end
    end

    describe "#regenerate_future!" do
      it "updates non-detached future materialized items in place, preserving id" do
        Timecop.freeze(Time.zone.local(2026, 5, 13, 8, 0)) do
          sched = build_schedule(
            kind:             "event",
            name:             "Old",
            start_time:       "10:00",
            duration_minutes: 30,
            recurrence:       { "freq" => "daily" },
            starts_on:        Date.current - 1,
          )
          # Saving the schedule already materialized whatever fell inside the
          # window. Clear it so the row under test is the only one on its date —
          # `materialize_upcoming!` keys existing rows by date and keeps the FIRST
          # per date, so a second row on the same day is a coin flip.
          AgendaItem.where(agenda_schedule_id: sched.id).delete_all
          tomorrow = Date.current + 1
          existing = sched.agenda_items.create!(
            agenda:   agenda, kind: "event",
            name:     "Old",
            start_at: ActiveSupport::TimeZone[user.timezone].local(tomorrow.year, tomorrow.month, tomorrow.day, 10, 0),
            end_at:   ActiveSupport::TimeZone[user.timezone].local(tomorrow.year, tomorrow.month, tomorrow.day, 10, 30),
          )
          sched.update!(name: "New", start_time: "15:00")
          existing.reload
          expect(existing.name).to eq("New")
          expect(existing.start_at.in_time_zone(user.timezone).hour).to eq(15)
        end
      end

      it "preserves detached items untouched" do
        sched = build_schedule(recurrence: { "freq" => "daily" }, starts_on: Date.current - 1)
        Timecop.freeze(Time.zone.local(2026, 5, 13, 8, 0)) do
          detached = sched.agenda_items.create!(
            agenda:      agenda, kind: "task",
            name:        "Kept",
            start_at:    Date.current + 3,
            detached_at: Time.current,
          )
          sched.update!(name: "Renamed")
          expect(detached.reload.name).to eq("Kept")
        end
      end

      it "destroys non-detached items whose date no longer matches the recurrence" do
        Timecop.freeze(Time.zone.local(2026, 5, 13, 8, 0)) do
          # Saturday is 2026-05-16.
          sched = build_schedule(recurrence: { "freq" => "daily" }, starts_on: Date.current - 1)
          saturday = sched.agenda_items.create!(
            agenda:   agenda, kind: "task",
            name:     "Sat",
            start_at: ActiveSupport::TimeZone[user.timezone].local(2026, 5, 16, 8, 0),
          )
          sched.update!(recurrence: { "freq" => "weekdays" })
          expect(sched.agenda_items.find_by(id: saturday.id)).to be_nil
        end
      end

      it "propagates metadata per-key when item still matches old schedule value" do
        Timecop.freeze(Time.zone.local(2026, 5, 13, 8, 0)) do
          sched = build_schedule(
            kind:             "event",
            start_time:       "10:00",
            duration_minutes: 30,
            recurrence:       { "freq" => "daily" },
            starts_on:        Date.current - 1,
            metadata:         { "travel_minutes" => 10, "travel_location" => "A" },
          )
          # See above: one row per date, or which one gets updated is arbitrary.
          AgendaItem.where(agenda_schedule_id: sched.id).delete_all
          tomorrow = Date.current + 1
          item = sched.agenda_items.create!(
            agenda:   agenda, kind: "event",
            name:     sched.name,
            start_at: ActiveSupport::TimeZone[user.timezone].local(tomorrow.year, tomorrow.month, tomorrow.day, 10, 0),
            end_at:   ActiveSupport::TimeZone[user.timezone].local(tomorrow.year, tomorrow.month, tomorrow.day, 10, 30),
            metadata: { "travel_minutes" => 10, "travel_location" => "A" },
          )
          sched.update!(metadata: { "travel_minutes" => 25, "travel_location" => "B" })
          expect(item.reload.metadata).to eq("travel_minutes" => 25, "travel_location" => "B")
        end
      end

      it "preserves item-only metadata keys (e.g. Jil-cached) when schedule metadata changes" do
        Timecop.freeze(Time.zone.local(2026, 5, 13, 8, 0)) do
          sched = build_schedule(
            kind:             "event",
            start_time:       "10:00",
            duration_minutes: 30,
            recurrence:       { "freq" => "daily" },
            starts_on:        Date.current - 1,
            metadata:         { "travel_minutes" => 10 },
          )
          tomorrow = Date.current + 1
          item = sched.agenda_items.create!(
            agenda:   agenda, kind: "event",
            name:     sched.name,
            start_at: ActiveSupport::TimeZone[user.timezone].local(tomorrow.year, tomorrow.month, tomorrow.day, 10, 0),
            end_at:   ActiveSupport::TimeZone[user.timezone].local(tomorrow.year, tomorrow.month, tomorrow.day, 10, 30),
            metadata: { "travel_minutes" => 99, "attendees" => ["x"] }, # diverged + item-only
          )
          sched.update!(metadata: { "travel_minutes" => 25 })
          expect(item.reload.metadata).to eq("travel_minutes" => 99, "attendees" => ["x"])
        end
      end
    end

    describe "Jil trigger lifecycle" do
      def trigger_capture
        triggered = []
        allow(::Jil).to receive(:trigger) { |_user, scope, data, **|
          triggered << [scope, data[:action]]
        }
        triggered
      end

      it "fires :created and :updated, and not on a metadata-only update" do
        triggered = trigger_capture
        sched = build_schedule(recurrence: { "freq" => "daily" })
        expect(triggered).to include([:agenda_schedule, :created])

        triggered.clear
        sched.update!(metadata: { travel_minutes: 12 })
        expect(triggered).to be_empty

        sched.update!(name: "Renamed")
        expect(triggered).to include([:agenda_schedule, :updated])
      end
    end

    describe "#build_phantom (metadata inheritance)" do
      it "copies the schedule's metadata and arrive_early_minutes onto every phantom" do
        sched = build_schedule(
          recurrence: { "freq" => "daily" },
          starts_on: Date.current,
          location: "123 Main St",
          arrive_early_minutes: 12,
          metadata: { travel_minutes: 33, travel_location: "123 Main St" },
        )
        phantom = sched.build_phantom(Date.current + 1)
        expect(phantom).to be_phantom
        expect(phantom.metadata).to eq("travel_minutes" => 33, "travel_location" => "123 Main St")
        expect(phantom.arrive_early_minutes).to eq(12)
        expect(sched.serialize_for_edit[:arrive_early_minutes]).to eq(12)
      end
    end
  end

  # Regression: AR's time_zone_aware_attributes converts time-column
  # values to UTC at write (using the current Time.zone, which carries
  # DST in summer) and reads back via Jan 1, 2000 as the base date
  # (always MST for Denver, no DST). The asymmetric conversion bled
  # 1 hour of DST out on every read. Fix: opt out of TZ conversion for
  # `start_time` so the wall-clock value round-trips losslessly.
  describe "start time and timezone" do
    describe "start_time wall-clock round-trip" do
      it "stores '15:00' as 15:00:00 regardless of the current Time.zone" do
        raw_per_zone = {}
        ["UTC", "America/Denver", "America/New_York"].each do |zone|
          Time.use_zone(zone) do
            u = create(:user, phone: 10.times.map { rand(0..9) }.join)
            a = create(:agenda, user: u)
            s = a.agenda_schedules.create!(
              kind: :event, name: "T", start_time: "15:00",
              starts_on: Date.new(2026, 5, 28), duration_minutes: 30,
              recurrence: { freq: "daily" }
            )
            raw = ActiveRecord::Base.connection.execute(
              "SELECT start_time::text FROM agenda_schedules WHERE id = #{s.id}"
            ).first["start_time"]
            raw_per_zone[zone] = raw
            expect(s.reload.start_time.hour).to eq(15), "Time.zone=#{zone}: got hour=#{s.start_time.hour}"
          end
        end
        expect(raw_per_zone.values.uniq).to eq(["15:00:00"]),
          "Expected all zones to store 15:00:00; got #{raw_per_zone}"
      end

      it "occurrence_start_at produces the right wall-clock for a DST-active date" do
        a = create(:agenda)
        s = a.agenda_schedules.create!(
          kind: :event, name: "T", start_time: "15:00",
          starts_on: Date.new(2026, 5, 28), duration_minutes: 30,
          recurrence: { freq: "daily" }
        )
        occ = s.occurrence_start_at(Date.new(2026, 5, 28))
        expect(occ.in_time_zone("America/Denver").strftime("%H:%M")).to eq("15:00")
      end
    end

    # start_time is the single source of truth for every kind. Every write
    # path keeps it aligned with the canonical value (user series-edit stamps
    # it directly; Google sync rewrites it from the master DTSTART on every
    # pull), so phantoms render at start_time everywhere. Materialized rows
    # carry their own per-instance start_at; they're not affected by phantom
    # render.
    describe "phantom wall-clock is always derived from start_time" do
      let(:agenda) { create(:agenda) }
      let(:schedule) {
        agenda.agenda_schedules.create!(
          kind: :event, name: "Tech Stand-Up", start_time: "10:30",
          duration_minutes: 30, starts_on: Date.new(2026, 3, 9),
          recurrence: { "freq" => "weekdays" }
        )
      }
      let(:user_zone) { ActiveSupport::TimeZone[agenda.user.timezone] }

      def wall_clock(sched, date)
        sched.occurrence_start_at(date).in_time_zone(agenda.user.timezone).strftime("%H:%M")
      end

      it "ignores past materialized occurrences sitting at a different wall-clock" do
        schedule.agenda_items.create!(
          agenda:   agenda, kind: :event, name: "Tech Stand-Up",
          start_at: user_zone.local(2026, 6, 1, 9, 30),
          end_at:   user_zone.local(2026, 6, 1, 10, 0),
        )

        expect(wall_clock(schedule, Date.new(2026, 3, 10))).to eq("10:30")
        expect(wall_clock(schedule, Date.new(2026, 6, 2))).to eq("10:30")
      end

      it "honours a freshly-edited start_time on the next phantom even after past occurrences exist" do
        schedule.agenda_items.create!(
          agenda:   agenda, kind: :event, name: "Tech Stand-Up",
          start_at: user_zone.local(2026, 6, 1, 10, 30),
          end_at:   user_zone.local(2026, 6, 1, 11, 0),
        )
        schedule.update!(start_time: "14:00")

        expect(wall_clock(schedule, Date.new(2026, 6, 2))).to eq("14:00")
      end

      it "applies to task schedules too" do
        task_sched = agenda.agenda_schedules.create!(
          kind: :task, name: "Brush teeth", start_time: "07:00",
          starts_on: Date.new(2026, 3, 9), recurrence: { "freq" => "daily" }
        )
        task_sched.agenda_items.create!(
          agenda: agenda, kind: :task, name: "Brush teeth",
          start_at: user_zone.local(2026, 5, 28, 9, 0),
        )

        expect(wall_clock(task_sched, Date.new(2026, 5, 30))).to eq("07:00")
      end
    end
  end

  describe "occurrence_count" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }

    it "derives until_on from occurrence_count on save", :aggregate_failures do
      [
        # 14, 15, 16, 17, 18
        [{ "freq" => "daily" }, 5, Date.new(2026, 5, 18)],
        # Thu, Fri, Mon, Tue, Wed
        [{ "freq" => "weekdays" }, 5, Date.new(2026, 5, 20)],
        # 14, 21, 28, June 4
        [{ "freq" => "weekly", "by_day" => ["thu"] }, 4, Date.new(2026, 6, 4)],
      ].each do |recurrence, count, until_on|
        sched = create(:agenda_schedule, agenda: agenda,
          recurrence: recurrence, starts_on: Date.new(2026, 5, 14), occurrence_count: count)
        expect(sched.until_on).to eq(until_on), recurrence.inspect
      end
    end

    it "matches? respects the derived until_on (count-based bound)" do
      sched = create(:agenda_schedule, agenda: agenda,
        recurrence: { "freq" => "daily" },
        starts_on:  Date.new(2026, 5, 14),
        occurrence_count: 3)
      expect(sched.matches?(Date.new(2026, 5, 14))).to be true
      expect(sched.matches?(Date.new(2026, 5, 16))).to be true
      expect(sched.matches?(Date.new(2026, 5, 17))).to be false
    end

    it "validates occurrence_count is a positive integer" do
      expect(build(:agenda_schedule, agenda: agenda, occurrence_count: 0)).not_to be_valid
      expect(build(:agenda_schedule, agenda: agenda, occurrence_count: -1)).not_to be_valid
      expect(build(:agenda_schedule, agenda: agenda, occurrence_count: 1)).to be_valid
      expect(build(:agenda_schedule, agenda: agenda, occurrence_count: nil)).to be_valid
    end

    it "phantoms only generate up to the count-derived until_on" do
      sched = create(:agenda_schedule, agenda: agenda,
        recurrence: { "freq" => "weekly", "by_day" => ["thu"] },
        starts_on:  Date.new(2026, 5, 14),
        occurrence_count: 3)
      # Past the last occurrence — phantom_for returns nil
      expect(sched.phantom_for(Date.new(2026, 6, 4))).to be_nil  # That's the 4th Thursday — past count
      expect(sched.phantom_for(Date.new(2026, 5, 28))).to be_present # 3rd Thursday — within count
    end
  end

  # The series half of AgendaItem's live-update broadcast. A repeat only
  # materializes rows 30 hours out, so the views draw most of it as phantoms
  # off the rule, and the rule itself has to reach the page.
  describe "the live-update broadcast" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }

    def agenda_payloads
      payloads = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload| payloads << payload }
      yield
      payloads.select { |p| p[:id] == :agenda }
    end

    it "announces a series created outside a controller, and a rule edit" do
      sched = nil
      expect(agenda_payloads {
        sched = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "weekly", "by_day" => ["tue"] })
      }).not_to be_empty
      expect(agenda_payloads { sched.update!(name: "Standup, moved") }).not_to be_empty
    end

    # JilScheduleWorker walks every schedule once a minute.
    it "stays quiet on a save that changed nothing" do
      sched = create(:agenda_schedule, agenda: agenda)

      expect(agenda_payloads { sched.update!(name: sched.name) }).to be_empty
    end
  end
end
