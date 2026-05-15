require "rails_helper"

RSpec.describe AgendaNotificationSetting do
  let(:owner)  { create(:user) }
  let(:agenda) { create(:agenda, user: owner) }

  describe "defaults via .for when no row exists" do
    it "defaults task on, event on, trigger off (for both recurrences)" do
      setting = described_class.for(owner, agenda)
      expect(setting.notify_task_oneoff).to be true
      expect(setting.notify_task_recurring).to be true
      expect(setting.notify_event_oneoff).to be true
      expect(setting.notify_event_recurring).to be true
      expect(setting.notify_trigger_oneoff).to be false
      expect(setting.notify_trigger_recurring).to be false
    end

    it "returns the persisted row when one exists" do
      row = described_class.create!(user: owner, agenda: agenda,
        notify_task_oneoff: false, notify_event_recurring: false)
      setting = described_class.for(owner, agenda)
      expect(setting.id).to eq(row.id)
      expect(setting.notify_task_oneoff).to be false
      expect(setting.notify_event_recurring).to be false
    end
  end

  describe "#notify_for?" do
    let(:setting) { described_class.for(owner, agenda) }

    it "matches kind × recurrence" do
      oneoff_task = build(:agenda_item, agenda: agenda, kind: :task, agenda_schedule: nil)
      expect(setting.notify_for?(oneoff_task)).to be true
    end

    it "respects user-customized state" do
      setting.notify_event_recurring = false
      setting.save!
      sched = create(:agenda_schedule, agenda: agenda, kind: :event,
        start_time: "09:00", duration_minutes: 30)
      recurring_event = build(:agenda_item, agenda: agenda, kind: :event,
        agenda_schedule: sched, end_at: 1.hour.from_now)
      oneoff_event = build(:agenda_item, agenda: agenda, kind: :event,
        agenda_schedule: nil, end_at: 1.hour.from_now)
      expect(setting.notify_for?(recurring_event)).to be false
      expect(setting.notify_for?(oneoff_event)).to be true
    end
  end

  describe "uniqueness" do
    it "is one row per (user, agenda)" do
      described_class.create!(user: owner, agenda: agenda)
      dup = described_class.new(user: owner, agenda: agenda)
      expect(dup).not_to be_valid
    end
  end
end
