require "rails_helper"

# Regression + feature coverage for the agenda that Buddy reads. The old code
# called a non-existent `i.title`, so `today_agenda` always rescued to [] —
# Buddy never saw the agenda at all.
RSpec.describe Buddy::Context, ".build agenda" do
  let(:user)   { create(:user) }
  let(:conversation) { user.byte_conversations.create!(mode: :buddy) }
  let(:agenda) { create(:agenda, user: user) }
  let(:schedule) { create(:agenda_schedule, agenda: agenda) }

  # "Today" is a real window in the user's zone, so an item placed a few hours
  # out lands in TOMORROW when the suite runs late enough in the evening - these
  # passed all day and failed after 9pm. Mid-morning keeps every relative offset
  # below on the day the examples mean.
  around { |ex| travel_to(Time.zone.parse("2026-07-15 15:00 UTC")) { ex.run } }

  def item(attrs)
    create(:agenda_item, { agenda: agenda }.merge(attrs))
  end

  it "surfaces today's items (name + cadence), the bug that returned []" do
    item(name: "Vet appt",  start_at: Time.current + 3.hours)                            # one-off
    item(name: "Standup",   start_at: Time.current + 2.hours, agenda_schedule: schedule) # daily routine

    today = described_class.build(user, conversation)[:today_agenda]

    expect(today.map { |i| i[:title] }).to include("Vet appt", "Standup")
    # one-off → no cadence key (glossing is only for the daily repeats)
    expect(today.find { |i| i[:title] == "Vet appt" }[:cadence]).to be_nil
    expect(today.find { |i| i[:title] == "Standup"  }[:cadence]).to eq("daily")
  end

  it "labels a less-frequent cadence so it can still be mentioned" do
    monthly = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "monthly" })
    item(name: "1:1 with Eric", start_at: Time.current + 2.hours, agenda_schedule: monthly)

    today = described_class.build(user, conversation)[:today_agenda]
    expect(today.find { |i| i[:title] == "1:1 with Eric" }[:cadence]).to eq("monthly")
  end

  it "includes known drive time for a soon item" do
    item(name: "Offsite", start_at: Time.current + 3.hours, metadata: { "travel" => { "travel_minutes" => 25 } })

    today = described_class.build(user, conversation)[:today_agenda]
    expect(today.find { |i| i[:title] == "Offsite" }[:drive_min]).to eq(25)
  end

  it "builds a proximity-labelled rest-of-week view" do
    item(name: "Dentist",  start_at: Time.current + 3.days)                              # one-off, upcoming
    item(name: "Today thing", start_at: Time.current)                                    # right now → today, NOT in upcoming

    upcoming = described_class.build(user, conversation)[:upcoming_agenda]
    titles = upcoming.map { |i| i[:title] }

    expect(titles).to include("Dentist")
    expect(titles).not_to include("Today thing")
    expect(upcoming.find { |i| i[:title] == "Dentist" }[:day]).to be_present
  end

  # "The weekend has a pickup Saturday" was `Pickup B and Saya`, 4pm, at the
  # airport — so the one useful fact, who was being collected, went missing
  # along with where. The name was in context; the place was not, and a briefing
  # can only be as specific as what it was handed.
  it "carries where an item is, not just what it's called" do
    item(name: "Pickup B and Saya", start_at: Time.current + 5.days, location: "airport")

    built = described_class.build(user, conversation)
    pickup = built[:upcoming_agenda].find { |i| i[:title] == "Pickup B and Saya" }

    expect(pickup[:where]).to eq("airport")
  end

  it "carries it for today's items too" do
    item(name: "Lunch", start_at: Time.current + 2.hours, location: "The Rose Establishment")

    today = described_class.build(user, conversation)[:today_agenda]

    expect(today.find { |i| i[:title] == "Lunch" }[:where]).to eq("The Rose Establishment")
  end

  it "leaves the key off entirely when there's no location to give" do
    item(name: "Dentist", start_at: Time.current + 3.days)

    upcoming = described_class.build(user, conversation)[:upcoming_agenda]

    expect(upcoming.find { |i| i[:title] == "Dentist" }).not_to have_key(:where)
  end

  # The agenda half of the list problem. Aug 10's briefing opened with two
  # weekday-recurring meetings and put the day's only one-off third — the
  # routine outnumbered the notable, so the routine is what got read out. The
  # briefing is handed only the items that make the day unlike any other.
  describe "the notable-only view a briefing gets" do
    def weekdays_schedule
      create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "weekdays" })
    end

    it "drops the standing weekday repeats and keeps the one-off" do
      item(name: "Standup", start_at: Time.current + 1.hour, agenda_schedule: weekdays_schedule)
      item(name: "Launch Readiness", start_at: Time.current + 3.hours)

      notable = described_class.build(user, conversation)[:today_notable]

      expect(notable.pluck(:title)).to eq(["Launch Readiness"])
    end

    it "keeps a rarely-recurring one, which isn't top of mind" do
      monthly = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "monthly" })
      item(name: "One on one", start_at: Time.current + 2.hours, agenda_schedule: monthly)

      notable = described_class.build(user, conversation)[:today_notable]

      expect(notable.pluck(:title)).to include("One on one")
    end

    # A normal thing missing beats a normal thing present.
    it "keeps a routine that ISN'T happening" do
      item(
        name: "Standup", start_at: Time.current + 1.hour,
        agenda_schedule: weekdays_schedule, status: :cancelled,
      )

      notable = described_class.build(user, conversation)[:today_notable]

      expect(notable.pluck(:title)).to include("Standup")
    end

    it "filters the week the same way" do
      item(name: "Standup", start_at: Time.current + 2.days, agenda_schedule: weekdays_schedule)
      item(name: "Dentist", start_at: Time.current + 2.days)

      notable = described_class.build(user, conversation)[:upcoming_notable]

      expect(notable.pluck(:title)).to eq(["Dentist"])
    end

    # Withheld from the briefing, not deleted — a direct question about the
    # calendar still gets the whole thing.
    it "leaves the full lists in place for everyone else" do
      item(name: "Standup", start_at: Time.current + 1.hour, agenda_schedule: weekdays_schedule)

      built = described_class.build(user, conversation)

      expect(built[:today_agenda].pluck(:title)).to include("Standup")
    end
  end

  it "does NOT put a tomorrow all-day event in today (the birthday-shows-today bug)" do
    # An all-day event is stored at the LOCAL midnight of its date. The old
    # today window (`now .. now+24h`) reached into tomorrow, so a tomorrow
    # birthday landed in today. It belongs to the week view as "tomorrow".
    tz = user.timezone
    tomorrow_midnight = Time.current.in_time_zone(tz).beginning_of_day + 1.day
    item(name: "Andrew's Bday", all_day: true, start_at: tomorrow_midnight, end_at: tomorrow_midnight + 1.day)

    built = described_class.build(user, conversation)
    expect(built[:today_agenda].map { |i| i[:title] }).not_to include("Andrew's Bday")

    tomorrow = built[:upcoming_agenda].find { |i| i[:title] == "Andrew's Bday" }
    expect(tomorrow).to be_present
    expect(tomorrow[:day]).to eq("tomorrow")
    expect(tomorrow[:time]).to eq("all day")
  end

  it "tags a partner's shared PERSONAL item as not-mine, but treats an owned item as mine" do
    partner = create(:user)  # first_name falls back to username for a non-mapped id

    # Partner's personal calendar, shared TO this user → awareness-only.
    hers = create(:agenda, user: partner)
    AgendaShare.create!(agenda: hers, user: user, permission: :viewer)
    create(:agenda_item, agenda: hers, name: "Partner Ortho", start_at: Time.current + 2.hours)

    # The user's own event on their own calendar → theirs.
    item(name: "My Standup", start_at: Time.current + 1.hour)

    today = described_class.build(user, conversation)[:today_agenda]
    hers_row = today.find { |i| i[:title] == "Partner Ortho" }
    mine_row = today.find { |i| i[:title] == "My Standup" }

    expect(hers_row[:mine]).to be(false)
    expect(hers_row[:owner]).to eq(partner.first_name)
    expect(mine_row).not_to have_key(:mine)   # owned → no ownership tag
  end

  it "keeps a cancelled ROUTINE (heads-up) but drops a cancelled one-off (noise)" do
    item(name: "No standup", start_at: Time.current + 1.day, agenda_schedule: schedule, status: :cancelled)
    item(name: "Dropped",    start_at: Time.current + 2.days, status: :cancelled)

    upcoming = described_class.build(user, conversation)[:upcoming_agenda]
    titles = upcoming.map { |i| i[:title] }

    expect(titles).to include("No standup")
    expect(titles).not_to include("Dropped")
    expect(upcoming.find { |i| i[:title] == "No standup" }[:cancelled]).to be(true)
  end
end
