require "rails_helper"

# Regression + feature coverage for the agenda that Buddy reads. The old code
# called a non-existent `i.title`, so `today_agenda` always rescued to [] —
# Buddy never saw the agenda at all.
RSpec.describe Buddy::Context, ".build agenda" do
  let(:user)   { create(:user) }
  let(:agenda) { create(:agenda, user: user) }
  let(:schedule) { create(:agenda_schedule, agenda: agenda) }

  def item(attrs)
    create(:agenda_item, { agenda: agenda }.merge(attrs))
  end

  it "surfaces today's items (name + cadence), the bug that returned []" do
    item(name: "Vet appt",  start_at: Time.current + 3.hours)                            # one-off
    item(name: "Standup",   start_at: Time.current + 2.hours, agenda_schedule: schedule) # daily routine

    today = described_class.build(user)[:today_agenda]

    expect(today.map { |i| i[:title] }).to include("Vet appt", "Standup")
    # one-off → no cadence key (glossing is only for the daily repeats)
    expect(today.find { |i| i[:title] == "Vet appt" }[:cadence]).to be_nil
    expect(today.find { |i| i[:title] == "Standup"  }[:cadence]).to eq("daily")
  end

  it "labels a less-frequent cadence so it can still be mentioned" do
    monthly = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "monthly" })
    item(name: "1:1 with Eric", start_at: Time.current + 2.hours, agenda_schedule: monthly)

    today = described_class.build(user)[:today_agenda]
    expect(today.find { |i| i[:title] == "1:1 with Eric" }[:cadence]).to eq("monthly")
  end

  it "includes known drive time for a soon item" do
    item(name: "Offsite", start_at: Time.current + 3.hours, metadata: { "travel" => { "travel_minutes" => 25 } })

    today = described_class.build(user)[:today_agenda]
    expect(today.find { |i| i[:title] == "Offsite" }[:drive_min]).to eq(25)
  end

  it "builds a proximity-labelled rest-of-week view" do
    item(name: "Dentist",  start_at: Time.current + 3.days)                              # one-off, upcoming
    item(name: "Today thing", start_at: Time.current)                                    # right now → today, NOT in upcoming

    upcoming = described_class.build(user)[:upcoming_agenda]
    titles = upcoming.map { |i| i[:title] }

    expect(titles).to include("Dentist")
    expect(titles).not_to include("Today thing")
    expect(upcoming.find { |i| i[:title] == "Dentist" }[:day]).to be_present
  end

  it "keeps a cancelled ROUTINE (heads-up) but drops a cancelled one-off (noise)" do
    item(name: "No standup", start_at: Time.current + 1.day, agenda_schedule: schedule, status: :cancelled)
    item(name: "Dropped",    start_at: Time.current + 2.days, status: :cancelled)

    upcoming = described_class.build(user)[:upcoming_agenda]
    titles = upcoming.map { |i| i[:title] }

    expect(titles).to include("No standup")
    expect(titles).not_to include("Dropped")
    expect(upcoming.find { |i| i[:title] == "No standup" }[:cancelled]).to be(true)
  end
end
