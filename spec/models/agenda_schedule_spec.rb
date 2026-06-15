require "rails_helper"

RSpec.describe AgendaSchedule do
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
    it "destroys non-detached future materialized items" do
      sched = build_schedule(recurrence: { "freq" => "daily" }, starts_on: Date.current - 1)
      Timecop.freeze(Time.zone.local(2026, 5, 13, 8, 0)) do
        sched.agenda_items.create!(
          agenda:   agenda, kind: "task",
          name:     "Mat",
          start_at: Date.current + 2,
        )
        detached = sched.agenda_items.create!(
          agenda:      agenda, kind: "task",
          name:        "Kept",
          start_at:    Date.current + 3,
          detached_at: Time.current,
        )
        sched.regenerate_future!
        expect(sched.agenda_items.find_by(id: detached.id)).to be_present
        expect(sched.agenda_items.count).to eq(1)
      end
    end
  end
end
