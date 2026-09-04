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

    describe "kind enum" do
      it "is integer-backed" do
        expect(AgendaSchedule.columns_hash["kind"].type).to eq(:integer)
        expect(AgendaSchedule.kinds).to eq("task" => 0, "event" => 1, "trigger" => 2)
      end
    end

    describe "validations" do
      it "requires duration_minutes for event kind" do
        sched = build(:agenda_schedule, agenda: agenda, kind: "event", duration_minutes: nil)
        expect(sched).not_to be_valid
      end

      it "allows nil duration for task kind" do
        sched = build(:agenda_schedule, agenda: agenda, kind: "task", duration_minutes: nil)
        expect(sched).to be_valid
      end
    end

    describe "#matches?" do
      it "daily matches every day from starts_on" do
        sched = build_schedule(recurrence: { "freq" => "daily" }, starts_on: Date.new(2026, 5, 1))
        expect(sched.matches?(Date.new(2026, 5, 1))).to be true
        expect(sched.matches?(Date.new(2026, 5, 15))).to be true
        expect(sched.matches?(Date.new(2026, 4, 30))).to be false
      end

      it "weekdays matches Mon-Fri only" do
        sched = build_schedule(recurrence: { "freq" => "weekdays" }, starts_on: Date.new(2026, 5, 1))
        expect(sched.matches?(Date.new(2026, 5, 4))).to be true
        expect(sched.matches?(Date.new(2026, 5, 9))).to be false
      end

      it "weekly with by_day" do
        sched = build_schedule(
          recurrence: { "freq" => "weekly", "by_day" => %w[mon wed fri] },
          starts_on:  Date.new(2026, 5, 1),
        )
        expect(sched.matches?(Date.new(2026, 5, 4))).to be true
        expect(sched.matches?(Date.new(2026, 5, 5))).to be false
      end

      it "monthly with by_month_day" do
        sched = build_schedule(
          recurrence: { "freq" => "monthly", "by_month_day" => [1, 15] },
          starts_on:  Date.new(2026, 5, 1),
        )
        expect(sched.matches?(Date.new(2026, 5, 15))).to be true
        expect(sched.matches?(Date.new(2026, 5, 20))).to be false
      end

      it "monthly with by_set_pos+by_day — every third Tuesday" do
        sched = build_schedule(
          recurrence: { "freq" => "monthly", "by_set_pos" => 3, "by_day" => ["tue"] },
          starts_on:  Date.new(2026, 5, 19), # 3rd Tue of May 2026
        )
        expect(sched.matches?(Date.new(2026, 5, 19))).to be true   # 3rd Tue May
        expect(sched.matches?(Date.new(2026, 6, 16))).to be true   # 3rd Tue June
        expect(sched.matches?(Date.new(2026, 5, 12))).to be false  # 2nd Tue
        expect(sched.matches?(Date.new(2026, 5, 20))).to be false  # 3rd Wed
      end

      it "custom monthly on Nth weekday — every second Thursday" do
        sched = build_schedule(
          recurrence: { "freq" => "custom", "interval" => 1, "unit" => "month",
                        "by_set_pos" => 2, "by_day" => ["thu"] },
          starts_on:  Date.new(2026, 5, 14), # 2nd Thursday of May 2026
        )
        expect(sched.matches?(Date.new(2026, 5, 14))).to be true   # 2nd Thu May
        expect(sched.matches?(Date.new(2026, 6, 11))).to be true   # 2nd Thu June
        expect(sched.matches?(Date.new(2026, 5, 7))).to be false   # 1st Thu (wrong week)
        expect(sched.matches?(Date.new(2026, 5, 21))).to be false  # 3rd Thu
        expect(sched.matches?(Date.new(2026, 5, 15))).to be false  # Fri (wrong weekday)
      end

      it "custom monthly on LAST weekday — every last Friday" do
        sched = build_schedule(
          recurrence: { "freq" => "custom", "interval" => 1, "unit" => "month",
                        "by_set_pos" => -1, "by_day" => ["fri"] },
          starts_on:  Date.new(2026, 5, 29), # last Fri of May 2026
        )
        expect(sched.matches?(Date.new(2026, 5, 29))).to be true   # last Fri May
        expect(sched.matches?(Date.new(2026, 6, 26))).to be true   # last Fri June
        expect(sched.matches?(Date.new(2026, 5, 22))).to be false  # 2nd-to-last Fri
      end

      it "custom every 3 months on Nth weekday — third Tuesday quarterly (the All Hands rule)" do
        sched = build_schedule(
          recurrence: { "freq" => "custom", "interval" => 3, "unit" => "month",
                        "by_set_pos" => 3, "by_day" => ["tue"] },
          starts_on:  Date.new(2026, 1, 20), # 3rd Tue Jan 2026
        )
        expect(sched.matches?(Date.new(2026, 1, 20))).to be true   # 3rd Tue Jan
        expect(sched.matches?(Date.new(2026, 4, 21))).to be true   # 3rd Tue Apr (3 months later)
        expect(sched.matches?(Date.new(2026, 7, 21))).to be true   # 3rd Tue Jul
        expect(sched.matches?(Date.new(2026, 2, 17))).to be false  # 3rd Tue Feb — wrong month interval
        expect(sched.matches?(Date.new(2026, 6, 20))).to be false  # Saturday in skipped month
        expect(sched.matches?(Date.new(2026, 4, 14))).to be false  # 2nd Tue Apr (wrong week)
      end

      it "custom every 2 months on by_month_day — 15th every other month" do
        sched = build_schedule(
          recurrence: { "freq" => "custom", "interval" => 2, "unit" => "month",
                        "by_month_day" => [15] },
          starts_on:  Date.new(2026, 1, 15),
        )
        expect(sched.matches?(Date.new(2026, 1, 15))).to be true
        expect(sched.matches?(Date.new(2026, 3, 15))).to be true   # 2 months later
        expect(sched.matches?(Date.new(2026, 2, 15))).to be false  # wrong month interval
        expect(sched.matches?(Date.new(2026, 3, 14))).to be false  # wrong day
      end

      it "custom every 3 days" do
        sched = build_schedule(
          recurrence: { "freq" => "custom", "interval" => 3, "unit" => "day" },
          starts_on:  Date.new(2026, 5, 1),
        )
        expect(sched.matches?(Date.new(2026, 5, 4))).to be true
        expect(sched.matches?(Date.new(2026, 5, 5))).to be false
      end

      it "yearly matches the same month+day in subsequent years" do
        sched = build_schedule(
          recurrence: { "freq" => "yearly" },
          starts_on:  Date.new(2026, 6, 15),
        )
        expect(sched.matches?(Date.new(2026, 6, 15))).to be true
        expect(sched.matches?(Date.new(2027, 6, 15))).to be true
        expect(sched.matches?(Date.new(2100, 6, 15))).to be true
        expect(sched.matches?(Date.new(2026, 6, 14))).to be false
        expect(sched.matches?(Date.new(2026, 7, 15))).to be false
        expect(sched.matches?(Date.new(2025, 6, 15))).to be false  # before starts_on
      end

      it "respects until_on" do
        sched = build_schedule(
          recurrence: { "freq" => "daily" },
          starts_on:  Date.new(2026, 5, 1),
          until_on:   Date.new(2026, 5, 5),
        )
        expect(sched.matches?(Date.new(2026, 5, 6))).to be false
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

      it "returns nil on a non-matching date" do
        expect(sched.phantom_for(Date.new(2026, 5, 9))).to be_nil
      end

      it "returns nil when the date is in excluded_dates" do
        sched.add_excluded_date!(Date.new(2026, 5, 4))
        expect(sched.excluded?(Date.new(2026, 5, 4))).to be true
        expect(sched.phantom_for(Date.new(2026, 5, 4))).to be_nil
      end

      it "returns nil when a real AgendaItem already exists for that date" do
        sched.agenda_items.create!(
          agenda:   agenda,
          kind:     "event",
          name:     "Materialized",
          start_at: sched.send(:occurrence_start_at, Date.new(2026, 5, 4)),
          end_at:   sched.send(:occurrence_end_at, Date.new(2026, 5, 4)),
        )
        expect(sched.phantom_for(Date.new(2026, 5, 4))).to be_nil
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

    # It lived in AgendaItemsController#apply_agenda_move! as two lines that had
    # to be remembered together. Buddy's edit_agenda_item is the second caller,
    # and so is `undo` - a series move that leaves its rows behind puts them
    # back on the old calendar the moment anything re-reads them.
    describe "moving a series between calendars" do
      let(:other) { create(:agenda, user: user, name: "Ours 💕") }

      def filed_under(schedule)
        AgendaItem.where(agenda_schedule_id: schedule.id).distinct.pluck(:agenda_id)
      end

      it "takes its occurrences with it" do
        schedule = build_schedule
        expect(filed_under(schedule)).to eq([agenda.id])

        schedule.update!(agenda: other)

        expect(filed_under(schedule)).to eq([other.id])
      end

      it "puts them back when the move is reverted" do
        schedule = build_schedule
        schedule.update!(agenda: other)

        schedule.update!(agenda: agenda)

        expect(filed_under(schedule)).to eq([agenda.id])
      end

      it "leaves them alone for an edit that isn't a move" do
        schedule = build_schedule
        expect { schedule.update!(name: "Renamed") }.not_to change { filed_under(schedule) }
      end
    end

    describe "#add_excluded_date!" do
      let(:sched) {
        build_schedule(
          kind:             "event",
          start_time:       "09:30",
          duration_minutes: 60,
          recurrence:       { "freq" => "weekdays" },
          starts_on:        Date.new(2026, 5, 4),
        )
      }
      let(:day) { Date.new(2026, 5, 4) }
      let(:day_start) { ActiveSupport::TimeZone[user.timezone].local(day.year, day.month, day.day, 9, 30) }
      let(:day_end) { day_start + 60.minutes }

      it "cancels a non-detached materialized phantom on that date" do
        item = sched.agenda_items.create!(
          agenda: agenda, kind: "event", name: "Phantom", start_at: day_start, end_at: day_end,
        )
        sched.add_excluded_date!(day)
        expect(item.reload.status).to eq("cancelled")
        expect(item.reload.cancelled_at).to be_present
      end

      it "leaves a detached override on that date untouched" do
        override = sched.agenda_items.create!(
          agenda:            agenda, kind: "event", name: "Override",
          start_at:          day_start, end_at: day_end,
          detached_at:       Time.current,
          original_start_at: day_start,
        )
        sched.add_excluded_date!(day)
        expect(override.reload.status).to eq("confirmed")
        expect(override.reload.cancelled_at).to be_nil
      end
    end

    describe "#occurrence_start_at" do
      it "uses the schedule's start_time as the wall-clock for phantoms even when a past materialized item carries a different time" do
        sched = build_schedule(
          kind:             "event",
          start_time:       "10:30",
          duration_minutes: 30,
          recurrence:       { "freq" => "weekdays" },
          starts_on:        Date.new(2026, 6, 1),
        )
        sched.agenda_items.create!(
          agenda:   agenda,
          kind:     "event",
          name:     "Past anchor at the OLD time",
          start_at: ActiveSupport::TimeZone[user.timezone].local(2026, 6, 8, 9, 30),
          end_at:   ActiveSupport::TimeZone[user.timezone].local(2026, 6, 8, 10, 0),
        )
        occ = sched.occurrence_start_at(Date.new(2026, 6, 9))
        local = occ.in_time_zone(user.timezone)
        expect([local.hour, local.min]).to eq([10, 30])
      end

      it "renders phantoms at the freshly-edited start_time after a series edit, ignoring past materialized rows" do
        sched = build_schedule(
          kind:             "event",
          start_time:       "10:30",
          duration_minutes: 30,
          recurrence:       { "freq" => "daily" },
          starts_on:        Date.new(2026, 6, 1),
        )
        sched.agenda_items.create!(
          agenda:   agenda,
          kind:     "event",
          name:     "Yesterday at the old time",
          start_at: ActiveSupport::TimeZone[user.timezone].local(2026, 6, 8, 10, 30),
          end_at:   ActiveSupport::TimeZone[user.timezone].local(2026, 6, 8, 11, 0),
        )
        sched.update!(start_time: "15:00")
        occ = sched.occurrence_start_at(Date.new(2026, 6, 9))
        local = occ.in_time_zone(user.timezone)
        expect([local.hour, local.min]).to eq([15, 0])
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

    describe "metadata column" do
      it "round-trips a hash via jsonb" do
        sched = build_schedule(recurrence: { "freq" => "daily" })
        sched.update!(metadata: { travel_minutes: 17, travel_location: "X" })
        expect(sched.reload.metadata).to eq("travel_minutes" => 17, "travel_location" => "X")
      end

      it "defaults to {}" do
        sched = build_schedule(recurrence: { "freq" => "daily" })
        expect(sched.metadata).to eq({})
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

      it "fires :agenda_schedule action=:created on create" do
        triggered = trigger_capture
        build_schedule(recurrence: { "freq" => "daily" })
        expect(triggered).to include([:agenda_schedule, :created])
      end

      it "fires :agenda_schedule action=:updated on a real-field update" do
        sched = build_schedule(recurrence: { "freq" => "daily" })
        triggered = trigger_capture
        sched.update!(name: "Renamed")
        expect(triggered).to include([:agenda_schedule, :updated])
      end

      it "does NOT refire on a metadata-only update" do
        sched = build_schedule(recurrence: { "freq" => "daily" })
        triggered = trigger_capture
        sched.update!(metadata: { travel_minutes: 12 })
        expect(triggered).to be_empty
      end
    end

    describe "#build_phantom (metadata inheritance)" do
      it "copies the schedule's metadata onto every phantom so views see travel-time without DB rows" do
        sched = build_schedule(
          recurrence: { "freq" => "daily" },
          starts_on: Date.current,
          location: "123 Main St",
          metadata: { travel_minutes: 33, travel_location: "123 Main St" },
        )
        phantom = sched.build_phantom(Date.current + 1)
        expect(phantom).to be_phantom
        expect(phantom.metadata).to eq("travel_minutes" => 33, "travel_location" => "123 Main St")
      end

      it "carries arrive_early_minutes onto the phantom" do
        sched = build_schedule(
          recurrence: { "freq" => "daily" },
          starts_on: Date.current,
          arrive_early_minutes: 12,
        )
        phantom = sched.build_phantom(Date.current + 1)
        expect(phantom.arrive_early_minutes).to eq(12)
      end
    end

    describe "arrive_early_minutes column" do
      it "defaults to 0" do
        sched = build_schedule(recurrence: { "freq" => "daily" }, starts_on: Date.current)
        expect(sched.reload.arrive_early_minutes).to eq(0)
      end

      it "is included in serialize_for_edit" do
        sched = build_schedule(
          recurrence: { "freq" => "daily" },
          starts_on: Date.current,
          arrive_early_minutes: 8,
        )
        expect(sched.serialize_for_edit[:arrive_early_minutes]).to eq(8)
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

      it "ignores past materialized occurrences sitting at a different wall-clock" do
        schedule.agenda_items.create!(
          agenda:   agenda, kind: :event, name: "Tech Stand-Up",
          start_at: user_zone.local(2026, 6, 1, 9, 30),
          end_at:   user_zone.local(2026, 6, 1, 10, 0),
        )

        phantom = schedule.occurrence_start_at(Date.new(2026, 6, 2))
        expect(phantom.in_time_zone(agenda.user.timezone).strftime("%H:%M")).to eq("10:30")
      end

      it "honours a freshly-edited start_time on the next phantom even after past occurrences exist" do
        schedule.agenda_items.create!(
          agenda:   agenda, kind: :event, name: "Tech Stand-Up",
          start_at: user_zone.local(2026, 6, 1, 10, 30),
          end_at:   user_zone.local(2026, 6, 1, 11, 0),
        )
        schedule.update!(start_time: "14:00")
        phantom = schedule.occurrence_start_at(Date.new(2026, 6, 2))
        expect(phantom.in_time_zone(agenda.user.timezone).strftime("%H:%M")).to eq("14:00")
      end

      it "uses start_time on a brand-new schedule with no materialized rows" do
        phantom = schedule.occurrence_start_at(Date.new(2026, 3, 10))
        expect(phantom.in_time_zone(agenda.user.timezone).strftime("%H:%M")).to eq("10:30")
      end

      it "task / trigger schedules also use start_time (unchanged behavior)" do
        task_sched = agenda.agenda_schedules.create!(
          kind: :task, name: "Brush teeth", start_time: "07:00",
          starts_on: Date.new(2026, 3, 9), recurrence: { "freq" => "daily" }
        )
        task_sched.agenda_items.create!(
          agenda: agenda, kind: :task, name: "Brush teeth",
          start_at: user_zone.local(2026, 5, 28, 9, 0),
        )
        phantom = task_sched.occurrence_start_at(Date.new(2026, 5, 30))
        expect(phantom.in_time_zone(agenda.user.timezone).strftime("%H:%M")).to eq("07:00")
      end
    end
  end

  describe "occurrence_count" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }

    it "derives until_on from a daily occurrence_count on save" do
      sched = create(:agenda_schedule, agenda: agenda,
        recurrence: { "freq" => "daily" },
        starts_on:  Date.new(2026, 5, 14),
        occurrence_count: 5)
      expect(sched.until_on).to eq(Date.new(2026, 5, 18)) # 5 days: 14, 15, 16, 17, 18
    end

    it "derives until_on for weekdays" do
      sched = create(:agenda_schedule, agenda: agenda,
        recurrence: { "freq" => "weekdays" },
        starts_on:  Date.new(2026, 5, 14), # Thu
        occurrence_count: 5)
      # Thu, Fri, Mon, Tue, Wed = 14, 15, 18, 19, 20
      expect(sched.until_on).to eq(Date.new(2026, 5, 20))
    end

    it "derives until_on for weekly with by_day" do
      sched = create(:agenda_schedule, agenda: agenda,
        recurrence: { "freq" => "weekly", "by_day" => ["thu"] },
        starts_on:  Date.new(2026, 5, 14),
        occurrence_count: 4)
      # 4 Thursdays starting May 14: 14, 21, 28, June 4
      expect(sched.until_on).to eq(Date.new(2026, 6, 4))
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
  # materializes rows 30 hours out, so "remind me every Tuesday" said on a
  # Thursday creates NO item — the week and month views draw it as a phantom
  # off the rule. Without the rule reaching the page, nothing appears there
  # until the tab is focused and AgendaSync polls on its own.
  describe "the live-update broadcast" do
    let(:user) { create(:user) }
    let(:agenda) { create(:agenda, user: user) }

    def agenda_payloads
      payloads = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload| payloads << payload }
      yield
      payloads.select { |p| p[:id] == :agenda }
    end

    it "announces a series created outside a controller" do
      sent = agenda_payloads {
        create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "weekly", "by_day" => ["tue"] })
      }

      expect(sent).not_to be_empty
    end

    it "announces a rule edit" do
      sched = create(:agenda_schedule, agenda: agenda)
      sent = agenda_payloads { sched.update!(name: "Standup, moved") }

      expect(sent).not_to be_empty
    end

    # JilScheduleWorker walks every schedule once a minute.
    it "stays quiet on a save that changed nothing" do
      sched = create(:agenda_schedule, agenda: agenda)

      expect(agenda_payloads { sched.update!(name: sched.name) }).to be_empty
    end
  end
end
