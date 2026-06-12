require "rails_helper"

RSpec.describe AgendaPreference, type: :model do
  let(:user) { create(:user, phone: 10.times.map { rand(0..9) }.join) }

  describe "writer normalization" do
    it "coerces hidden_schedule_ids to unique integers" do
      pref = AgendaPreference.new(user: user, hidden_schedule_ids: ["3", 3, "7", nil])
      expect(pref.hidden_schedule_ids).to eq([3, 7, 0])
    end

    it "strips, drops blanks, and dedupes hidden_name_patterns" do
      pref = AgendaPreference.new(user: user, hidden_name_patterns: [" focus ", "focus", "", nil, "daily standup"])
      expect(pref.hidden_name_patterns).to eq(["focus", "daily standup"])
    end
  end

  describe "validation" do
    it "rejects patterns that aren't valid regex" do
      pref = AgendaPreference.new(user: user, hidden_name_patterns: ["[unclosed"])
      expect(pref).not_to be_valid
      expect(pref.errors[:hidden_name_patterns].first).to include("invalid regex")
    end

    it "accepts valid regex patterns" do
      pref = AgendaPreference.new(user: user, hidden_name_patterns: ["^Focus$", "daily.*standup"])
      expect(pref).to be_valid
    end
  end

  describe "#item_hidden?" do
    let(:agenda)   { create(:agenda, user: user) }
    let(:schedule) { create(:agenda_schedule, agenda: agenda) }
    let(:item)     { create(:agenda_item, agenda: agenda, name: "Daily Standup") }

    it "returns false when no list matches" do
      pref = AgendaPreference.new(user: user)
      expect(pref.item_hidden?(item)).to eq(false)
    end

    it "matches hidden_agenda_ids" do
      pref = AgendaPreference.new(user: user, hidden_agenda_ids: [agenda.id])
      expect(pref.item_hidden?(item)).to eq(true)
    end

    it "matches hidden_schedule_ids when item belongs to that schedule" do
      item.update!(agenda_schedule: schedule)
      pref = AgendaPreference.new(user: user, hidden_schedule_ids: [schedule.id])
      expect(pref.item_hidden?(item)).to eq(true)
    end

    it "matches hidden_item_ids" do
      pref = AgendaPreference.new(user: user, hidden_item_ids: [item.id])
      expect(pref.item_hidden?(item)).to eq(true)
    end

    it "matches hidden_name_patterns case-insensitively" do
      pref = AgendaPreference.new(user: user, hidden_name_patterns: ["daily.*standup"])
      expect(pref.item_hidden?(item)).to eq(true)
    end

    it "ignores invalid regex patterns silently" do
      pref = AgendaPreference.new(user: user, hidden_name_patterns: ["[invalid"])
      pref.save(validate: false)
      expect(pref.item_hidden?(item)).to eq(false)
    end
  end

  describe "#serialize_for_client" do
    it "includes the new filter fields with names map for hidden schedules" do
      agenda   = create(:agenda, user: user)
      schedule = create(:agenda_schedule, agenda: agenda, name: "Daily Standup")
      pref = AgendaPreference.create!(
        user:                 user,
        hidden_schedule_ids:  [schedule.id],
        hidden_name_patterns: ["^Focus$"],
      )
      payload = pref.serialize_for_client
      expect(payload[:hidden_schedule_ids]).to eq([schedule.id])
      expect(payload[:hidden_schedule_names]).to eq(schedule.id => "Daily Standup")
      expect(payload[:hidden_name_patterns]).to eq(["^Focus$"])
    end
  end
end
