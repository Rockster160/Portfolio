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
end
