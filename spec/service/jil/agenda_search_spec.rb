require "rails_helper"

RSpec.describe Jil::Methods::Agenda, "#search" do
  let(:user) { create(:user) }
  let(:other_user) { create(:user, phone: "5559876543") }
  let(:agenda) { create(:agenda, user: user) }
  let(:other_agenda) { create(:agenda, user: other_user) }
  let(:jil) { double("jil_executor", user: user, ctx: {}) }
  let(:methods) { described_class.new(jil) }

  it "scopes results to the calling user's agendas" do
    mine = create(:agenda_item, agenda: agenda, kind: :task, name: "Mine",
      start_at: 1.hour.ago, completed_at: nil)
    _theirs = create(:agenda_item, agenda: other_agenda, kind: :task, name: "Theirs",
      start_at: 1.hour.ago, completed_at: nil)

    results = methods.search("kind:task incomplete", nil, nil)
    expect(results.pluck(:agenda_id)).to all(eq(agenda.id))
    expect(results.pluck(:id)).to include(mine.id.to_s)
  end

  it "materializes today's past-due phantoms so 'incomplete overdue' finds them" do
    # User timezone is America/Denver. Frozen time well past the schedule's
    # 14:00 local start time so occurrence_start_at < Time.current.
    Timecop.freeze(Time.utc(2026, 5, 14, 22, 0)) do
      schedule = create(:agenda_schedule, agenda: agenda, kind: :task,
        name: "Garbage Cans In", start_time: "14:00",
        recurrence: { "freq" => "daily" }, starts_on: Date.current - 1)

      expect(schedule.agenda_items.count).to eq(0)

      results = methods.search("kind:task incomplete overdue", 50, "ASC")
      expect(results.pluck(:name)).to include("Garbage Cans In")
      expect(schedule.agenda_items.where(start_at: ..Time.current).count).to be >= 1
    end
  end

  it "does NOT materialize phantoms that haven't reached their start_at yet" do
    # 13:00 UTC = ~07:00 MDT — before the 14:00 MDT schedule time.
    Timecop.freeze(Time.utc(2026, 5, 14, 13, 0)) do
      schedule = create(:agenda_schedule, agenda: agenda, kind: :task,
        name: "Future Task", start_time: "14:00",
        recurrence: { "freq" => "daily" }, starts_on: Date.current)

      methods.search("kind:task incomplete", 50, "ASC")
      expect(schedule.agenda_items.count).to eq(0)
    end
  end

  it "respects limit and order" do
    create(:agenda_item, agenda: agenda, kind: :task, name: "First",
      start_at: 3.hours.ago, completed_at: nil)
    create(:agenda_item, agenda: agenda, kind: :task, name: "Last",
      start_at: 1.hour.ago, completed_at: nil)

    asc = methods.search("kind:task incomplete", 50, "ASC")
    expect(asc.map { |h| h[:name] }).to eq(["First", "Last"])

    desc = methods.search("kind:task incomplete", 50, "DESC")
    expect(desc.map { |h| h[:name] }).to eq(["Last", "First"])

    limited = methods.search("kind:task incomplete", 1, "ASC")
    expect(limited.size).to eq(1)
  end
end
