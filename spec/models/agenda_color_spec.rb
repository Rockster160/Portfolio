require "rails_helper"

RSpec.describe "Agenda color cascade" do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user, color: "#0160FF") }

  describe "AgendaSchedule#display_color" do
    it "uses its own color when present" do
      sched = create(:agenda_schedule, agenda: agenda, color: "#ff8800")
      expect(sched.display_color).to eq("#ff8800")
    end

    it "falls back to the agenda's color when blank" do
      sched = create(:agenda_schedule, agenda: agenda, color: nil)
      expect(sched.display_color).to eq("#0160FF")
    end
  end

  describe "AgendaItem#display_color" do
    it "uses its own color when present" do
      item = create(:agenda_item, agenda: agenda, color: "#00ff00")
      expect(item.display_color).to eq("#00ff00")
    end

    it "falls back to the schedule's color when set" do
      sched = create(:agenda_schedule, agenda: agenda, color: "#ff8800")
      item = sched.agenda_items.create!(agenda: agenda, kind: "task",
        name: "X", start_at: 1.hour.from_now, color: nil)
      expect(item.display_color).to eq("#ff8800")
    end

    it "falls back to the agenda's color when neither set" do
      item = create(:agenda_item, agenda: agenda, color: nil)
      expect(item.display_color).to eq("#0160FF")
    end
  end

  describe "phantom inherits color from its schedule" do
    it "is the schedule's color even without an item.color" do
      sched = create(:agenda_schedule, agenda: agenda,
        recurrence: { "freq" => "daily" }, starts_on: Date.current,
        color: "#abcdef")
      phantom = sched.phantom_for(Date.current + 3)
      expect(phantom.color).to eq("#abcdef")
      expect(phantom.display_color).to eq("#abcdef")
    end
  end
end
