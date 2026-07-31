require "rails_helper"

RSpec.describe BirthdaySync do
  let(:user) { create(:user, phone: 10.times.map { rand(0..9) }.join) }

  def birthdays_agenda
    user.agendas.find_by(parameterized_name: "birthdays")
  end

  it "builds a read-only Birthdays calendar with a yearly all-day schedule per birthday contact" do
    user.contacts.create!(name: "Blake", last_name: "Condit", birth_month: 7, birth_day: 6)
    user.contacts.create!(
      name: "Stacy", last_name: "Prendiville", birth_month: 6, birth_day: 8, birth_year: 1995,
    )
    user.contacts.create!(name: "NoBday", last_name: "Person")

    agenda = described_class.call(user)

    expect(agenda.parameterized_name).to eq("birthdays")
    expect(agenda.read_only).to be(true)
    expect(agenda.source).to eq("user")
    expect(agenda.managed_externally?).to be(false)
    expect(user.editable_agendas).not_to include(agenda)

    scheds = agenda.agenda_schedules.order(:name)
    expect(scheds.map(&:name)).to eq(["Blake Condit's Birthday", "Stacy Prendiville's Birthday"])

    blake = scheds.find { |s| s.name.start_with?("Blake") }
    expect(blake.all_day).to be(true)
    expect(blake.freq).to eq(:yearly)
    expect([blake.starts_on.month, blake.starts_on.day]).to eq([7, 6])
    expect(blake.matches?(Date.new(2030, 7, 6))).to be(true)
    expect(blake.matches?(Date.new(2030, 7, 7))).to be(false)
  end

  it "is idempotent and prunes a schedule once the birthday is cleared" do
    contact = user.contacts.create!(name: "Tela", last_name: "Gonzalez", birth_month: 6, birth_day: 21)

    described_class.call(user)
    described_class.call(user)
    expect(birthdays_agenda.agenda_schedules.count).to eq(1)

    contact.update!(birth_month: nil, birth_day: nil)
    described_class.call(user)
    expect(birthdays_agenda.agenda_schedules.count).to eq(0)
  end

  it "renders the birthday as an all-day agenda item in a future year" do
    user.contacts.create!(name: "Doug", last_name: "Greer", birth_month: 11, birth_day: 6)

    items = user.agenda_items_for_range(Date.new(2030, 11, 1), Date.new(2030, 11, 30))
    bday = items.find { |i| i.name == "Doug Greer's Birthday" }
    expect(bday).to be_present
    expect(bday.all_day).to be(true)
  end

  it "handles a year-less Feb 29 birthday via the leap-year anchor" do
    user.contacts.create!(name: "Leap", last_name: "Day", birth_month: 2, birth_day: 29)

    sched = birthdays_agenda.agenda_schedules.first
    expect([sched.starts_on.month, sched.starts_on.day]).to eq([2, 29])
  end

  describe "Contact after_commit hook" do
    it "auto-creates the schedule on contact create" do
      contact = user.contacts.create!(name: "Kensei", last_name: "Murton", birth_month: 10, birth_day: 19)

      sched = birthdays_agenda.agenda_schedules
        .where("metadata ->> 'birthday_contact_id' = ?", contact.id.to_s).first
      expect(sched.name).to eq("Kensei Murton's Birthday")
    end

    it "renames the event when the contact's name changes" do
      contact = user.contacts.create!(name: "Kensei", last_name: "Murton", birth_month: 10, birth_day: 19)
      contact.update!(last_name: "Smith")

      expect(birthdays_agenda.agenda_schedules.first.name).to eq("Kensei Smith's Birthday")
    end

    it "removes the event when the birthday is cleared" do
      contact = user.contacts.create!(name: "Kensei", last_name: "Murton", birth_month: 10, birth_day: 19)
      contact.update!(birth_month: nil, birth_day: nil)

      expect(birthdays_agenda.agenda_schedules.count).to eq(0)
    end

    it "does not create an empty Birthdays calendar for a birthday-less contact" do
      user.contacts.create!(name: "Nobody", last_name: "Here")

      expect(birthdays_agenda).to be_nil
    end
  end

  describe "hiding duplicate birthday events on other calendars" do
    let(:gmail) { create(:agenda, user: user, name: "Gmail") }

    def yearly_event(name, month, day)
      create(
        :agenda_schedule,
        agenda: gmail, name: name, kind: :event, all_day: true,
        start_time: "00:00", duration_minutes: 1440,
        recurrence: { "freq" => "yearly" }, starts_on: Date.new(2022, month, day)
      )
    end

    def hidden_ids
      AgendaPreference.for(user).hidden_schedule_ids
    end

    it "hides a matching birthday event when the contact's birthday is added" do
      dup = yearly_event("Blake's Birthday", 7, 6)
      user.contacts.create!(name: "Blake", last_name: "Condit", birth_month: 7, birth_day: 6)

      expect(hidden_ids).to include(dup.id)
    end

    it "leaves a non-birthday event on the same day visible" do
      meeting = yearly_event("Blake Planning Sync", 7, 6)
      user.contacts.create!(name: "Blake", last_name: "Condit", birth_month: 7, birth_day: 6)

      expect(hidden_ids).not_to include(meeting.id)
    end

    it "leaves a different person's birthday on the same day visible" do
      other = yearly_event("Sarah's Birthday", 7, 6)
      user.contacts.create!(name: "Blake", last_name: "Condit", birth_month: 7, birth_day: 6)

      expect(hidden_ids).not_to include(other.id)
    end

    it "un-hides the duplicate when the birthday is cleared, preserving manual hides" do
      dup = yearly_event("Blake's Birthday", 7, 6)
      manual = yearly_event("Some Anniversary", 3, 1)
      AgendaPreference.for(user).update!(hidden_schedule_ids: [manual.id])

      contact = user.contacts.create!(name: "Blake", last_name: "Condit", birth_month: 7, birth_day: 6)
      expect(hidden_ids).to include(dup.id, manual.id)

      contact.update!(birth_month: nil, birth_day: nil)
      expect(hidden_ids).to include(manual.id)
      expect(hidden_ids).not_to include(dup.id)
    end
  end
end
