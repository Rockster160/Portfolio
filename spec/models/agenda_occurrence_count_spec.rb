require "rails_helper"

RSpec.describe "AgendaSchedule occurrence_count" do
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
