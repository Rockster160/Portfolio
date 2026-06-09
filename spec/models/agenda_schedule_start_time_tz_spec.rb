require "rails_helper"

# Regression: AR's time_zone_aware_attributes converts time-column
# values to UTC at write (using the current Time.zone, which carries
# DST in summer) and reads back via Jan 1, 2000 as the base date
# (always MST for Denver, no DST). The asymmetric conversion bled
# 1 hour of DST out on every read. Fix: opt out of TZ conversion for
# `start_time` so the wall-clock value round-trips losslessly.
RSpec.describe AgendaSchedule, type: :model do
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
