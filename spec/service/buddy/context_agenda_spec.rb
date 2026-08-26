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

  # Prod 4684: "Marcos Jones's birthday is all day". The field said "all day"
  # and the briefing used it as a predicate, which makes a duration out of a
  # day. Everything in today_agenda IS today, so that's what it says now, and
  # the flag is where "no clock time" lives.
  it "gives an all-day item today rather than a duration" do
    midnight = Time.current.in_time_zone(user.timezone).beginning_of_day
    item(name: "Marcos Jones's birthday", all_day: true, start_at: midnight, end_at: midnight + 1.day)

    today = described_class.build(user, conversation)[:today_agenda].find { |i| i[:title].include?("Marcos") }

    expect(today[:time]).to eq("today")
    expect(today[:all_day]).to be(true)
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

  # Prod 4482 named five of Chelsea's items and none of Rocco's own. The three
  # prompt paragraphs saying not to were already there, so the answer is the one
  # `leave_by` already got: don't show it. The clash is what survives the cut,
  # and it is computed here because this is the layer holding real timestamps.
  describe "a partner's item that runs into one of theirs" do
    let(:partner) { create(:user) }
    let(:hers) {
      create(:agenda, user: partner).tap { |a| AgendaShare.create!(agenda: a, user: user, permission: :viewer) }
    }

    def today
      described_class.build(user, conversation)[:today_agenda]
    end

    def row(title)
      today.find { |i| i[:title] == title }
    end

    it "marks the one that overlaps" do
      item(name: "My Standup", start_at: Time.current + 1.hour, end_at: Time.current + 2.hours)
      create(:agenda_item, agenda: hers, name: "Her Ortho",
             start_at: Time.current + 90.minutes, end_at: Time.current + 150.minutes)

      expect(row("Her Ortho")[:collides_with]).to eq("My Standup")
    end

    it "leaves the one that doesn't unmarked" do
      item(name: "My Standup", start_at: Time.current + 1.hour, end_at: Time.current + 2.hours)
      create(:agenda_item, agenda: hers, name: "Her Yoga",
             start_at: Time.current + 4.hours, end_at: Time.current + 5.hours)

      expect(row("Her Yoga")).not_to have_key(:collides_with)
    end

    it "never marks the person's own item" do
      item(name: "My Standup", start_at: Time.current + 1.hour, end_at: Time.current + 2.hours)
      item(name: "My Other",   start_at: Time.current + 90.minutes, end_at: Time.current + 150.minutes)

      expect(row("My Standup")).not_to have_key(:collides_with)
      expect(row("My Other")).not_to have_key(:collides_with)
    end

    # An all-day item on either side would otherwise run into everything, which
    # would keep the whole calendar and mean nothing.
    it "does not let an all-day item collide with the day" do
      item(name: "My Standup", start_at: Time.current.beginning_of_day, all_day: true)
      create(:agenda_item, agenda: hers, name: "Her Ortho",
             start_at: Time.current + 90.minutes, end_at: Time.current + 150.minutes)

      expect(row("Her Ortho")).not_to have_key(:collides_with)
    end

    it "marks nothing when they have nothing of their own that day" do
      create(:agenda_item, agenda: hers, name: "Her Ortho",
             start_at: Time.current + 90.minutes, end_at: Time.current + 150.minutes)

      expect(row("Her Ortho")).not_to have_key(:collides_with)
    end
  end

  # Prod 4524's real cause. `agenda_items` 1027 came off `agenda_schedules` 80,
  # which sits in Rocco's `hidden_schedule_ids` — `BirthdaySync` put it there so
  # the gmail copy wouldn't double the Birthdays calendar. Every screen in the
  # app honours that list; Buddy never looked at it, so 24 hidden series and one
  # hidden item were still reaching the model.
  describe "things the person has hidden in the agenda filters" do
    let(:pref) { AgendaPreference.for(user) }

    def today_titles
      described_class.build(user, conversation)[:today_agenda].pluck(:title)
    end

    def upcoming_titles
      described_class.build(user, conversation)[:upcoming_agenda].pluck(:title)
    end

    it "leaves out a hidden series" do
      schedule = create(:agenda_schedule, agenda: user.agendas.first, name: "Marcos' Birthday")
      item(name: "Marcos' Birthday", start_at: Time.current + 2.hours, agenda_schedule: schedule)
      item(name: "Tech Retro", start_at: Time.current + 3.hours)
      expect(today_titles).to include("Marcos' Birthday")

      pref.update!(hidden_schedule_ids: [schedule.id])

      expect(today_titles).to include("Tech Retro")
      expect(today_titles).not_to include("Marcos' Birthday")
    end

    it "leaves out a hidden one-off" do
      hidden = item(name: "Dentist", start_at: Time.current + 2.hours)
      expect(today_titles).to include("Dentist")

      pref.update!(hidden_item_ids: [hidden.id])

      expect(today_titles).not_to include("Dentist")
    end

    it "leaves out a whole hidden calendar, tomorrow as well as today" do
      other = create(:agenda, user: user)
      create(:agenda_item, agenda: other, name: "Payday", all_day: true,
             start_at: (Date.current + 2).beginning_of_day)
      pref.update!(hidden_agenda_ids: [other.id])

      expect(upcoming_titles).not_to include("Payday")
    end

    it "leaves everything else where it is" do
      item(name: "Tech Retro", start_at: Time.current + 3.hours)

      expect(today_titles).to include("Tech Retro")
    end
  end

  # Prod 4524: "Tomorrow's got a couple birthday all-days". There was one
  # birthday - items 1027 (`Marcos' Birthday`, agenda 14) and 1028 (`Marcos
  # Jones's Birthday`, agenda 32) are the same person on two of Rocco's own
  # calendars - so the count counted rows and the name went missing.
  describe "one all-day thing sitting on two calendars" do
    let(:other) { create(:agenda, user: user) }

    def upcoming
      described_class.build(user, conversation)[:upcoming_agenda]
    end

    it "hands it over once, carrying the name" do
      day = Date.current + 2
      item(name: "Marcos' Birthday", start_at: day.beginning_of_day, all_day: true)
      create(:agenda_item, agenda: other, name: "Marcos Jones's Birthday",
             start_at: day.beginning_of_day, all_day: true)

      titles = upcoming.pluck(:title)
      expect(titles.grep(/Marcos/).length).to eq(1)
      expect(titles).to include("Marcos' Birthday")
    end

    it "leaves two different all-days on one day alone" do
      day = Date.current + 2
      item(name: "Marcos' Birthday", start_at: day.beginning_of_day, all_day: true)
      create(:agenda_item, agenda: other, name: "Trash Day", start_at: day.beginning_of_day, all_day: true)

      expect(upcoming.pluck(:title)).to include("Marcos' Birthday", "Trash Day")
    end

    it "leaves the same name on two different days alone" do
      item(name: "Marcos' Birthday", start_at: (Date.current + 2).beginning_of_day, all_day: true)
      create(:agenda_item, agenda: other, name: "Marcos' Birthday",
             start_at: (Date.current + 3).beginning_of_day, all_day: true)

      expect(upcoming.pluck(:title).grep(/Marcos/).length).to eq(2)
    end

    # A timed thing on two calendars is two commitments until something says
    # otherwise, and an all-day is the only shape this is safe for.
    it "leaves timed items alone" do
      at = (Date.current + 2).beginning_of_day + 9.hours
      item(name: "Standup", start_at: at, end_at: at + 30.minutes)
      create(:agenda_item, agenda: other, name: "Standup", start_at: at, end_at: at + 30.minutes)

      expect(upcoming.pluck(:title).grep(/Standup/).length).to eq(2)
    end
  end

  # Prod, twice: Moss told Chelsea "there's supper on the shared calendar at
  # 6:00 PM for Rocco" (17 Aug) and "Rocco's dinner is at 6:00" (19 Aug). Both
  # are item 985 on "Ours 💕 ", which Chelsea co-OWNS. A share at :owner means
  # the calendar is hers too - Agenda#owned_by? and #subject_users have always
  # said so - but this map only looked at `user_id`, so a joint calendar reached
  # the second owner tagged as the first one's personal business, which the
  # briefing seed reads as "leave it out entirely".
  it "treats a calendar the person CO-OWNS as theirs, not as the other owner's" do
    partner = create(:user)
    ours = create(:agenda, user: partner, name: "Ours 💕 ")
    AgendaShare.create!(agenda: ours, user: user, permission: :owner)
    create(:agenda_item, agenda: ours, name: "Dinner", start_at: Time.current + 2.hours)

    today = described_class.build(user, conversation)[:today_agenda]
    dinner = today.find { |i| i[:title] == "Dinner" }

    expect(dinner).to be_present
    expect(dinner).not_to have_key(:mine)
    expect(dinner).not_to have_key(:owner)
  end

  # Prod 3951 and again 4040, the morning after the third prompt rule against
  # it: "Chelsea's Inclusion Cheer board meeting at 4:00 PM. It's a drive one
  # too, so you'd want to leave around 3:28 PM." A departure time is an
  # instruction to walk out of the door, and on a viewer's copy of somebody
  # else's calendar it is an instruction to go to their appointment.
  #
  # A fourth rule was not going to be the one that worked, so the number stops
  # reaching the model at all.
  describe "a departure time on somebody else's item" do
    # What the travel chain leaves behind: the drive and the get-there-early
    # buffer already subtracted, stored as an epoch.
    def travelled!(agenda, name)
      create(
        :agenda_item,
        agenda:   agenda,
        name:     name,
        start_at: Time.current + 3.hours,
        metadata: { "travel" => { "travel_minutes" => 27, "leave_at" => (Time.current + 2.hours).to_i } },
      )
    end

    def row(title)
      described_class.build(user, conversation)[:today_agenda].find { |i| i[:title] == title }
    end

    it "keeps it on the person's own item" do
      item(name: "Mine", start_at: Time.current + 3.hours)
      travelled!(user.agendas.first || create(:agenda, user: user), "My Drive")

      expect(row("My Drive")).to include(:leave_by, :drive_min)
    end

    it "strips it off a calendar shared in as a viewer" do
      partner = create(:user)
      hers = create(:agenda, user: partner)
      AgendaShare.create!(agenda: hers, user: user, permission: :viewer)
      travelled!(hers, "Her Board Meeting")

      expect(row("Her Board Meeting")).not_to include(:leave_by)
      expect(row("Her Board Meeting")).not_to include(:drive_min)
    end

    it "still tags who it belongs to" do
      partner = create(:user)
      hers = create(:agenda, user: partner)
      AgendaShare.create!(agenda: hers, user: user, permission: :viewer)
      travelled!(hers, "Her Board Meeting")

      expect(row("Her Board Meeting")[:mine]).to be(false)
      expect(row("Her Board Meeting")[:owner]).to eq(partner.first_name)
    end

    # A dinner they are both going to is one they both leave for, so a joint
    # calendar keeps its departure time.
    it "keeps it on a calendar they co-own" do
      partner = create(:user)
      ours = create(:agenda, user: partner, name: "Ours 💕 ")
      AgendaShare.create!(agenda: ours, user: user, permission: :owner)
      travelled!(ours, "Dinner Out")

      expect(row("Dinner Out")).to include(:leave_by, :drive_min)
    end
  end

  # An editor can add to somebody's calendar without it being theirs. Only
  # :owner carries co-ownership, so this is the line the fix must not cross.
  it "still holds a calendar shared at :editor at arm's length" do
    partner = create(:user)
    theirs = create(:agenda, user: partner)
    AgendaShare.create!(agenda: theirs, user: user, permission: :editor)
    create(:agenda_item, agenda: theirs, name: "Their Thing", start_at: Time.current + 2.hours)

    today = described_class.build(user, conversation)[:today_agenda]

    expect(today.find { |i| i[:title] == "Their Thing" }[:mine]).to be(false)
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

  # Prod: Moss opened its 8:30 briefing with "Rocco's Heads-down block is
  # already past" — item 949, 8am to 5pm, thirty minutes old with eight and a
  # half hours left. `passed` read start_at alone, so every timed item flipped
  # the moment it began and today_briefing.rb was told not to mention it. The
  # longer the block, the longer the briefing was wrong about the day.
  describe "the passed flag" do
    def event(attrs)
      item({ kind: :event }.merge(attrs))
    end

    it "does not call an event past while it is still running" do
      event(name: "Heads-down", start_at: Time.current - 30.minutes, end_at: Time.current + 8.hours)

      today = described_class.build(user, conversation)[:today_agenda]

      expect(today.find { |i| i[:title] == "Heads-down" }).not_to have_key(:passed)
    end

    it "calls it past once the end goes by" do
      event(name: "Standup", start_at: Time.current - 2.hours, end_at: Time.current - 90.minutes)

      today = described_class.build(user, conversation)[:today_agenda]

      expect(today.find { |i| i[:title] == "Standup" }[:passed]).to be(true)
    end

    # A task has no span, so it has nothing to still be inside of.
    it "still flips a task at its start" do
      item(name: "Call the vet", start_at: Time.current - 10.minutes)

      today = described_class.build(user, conversation)[:today_agenda]

      expect(today.find { |i| i[:title] == "Call the vet" }[:passed]).to be(true)
    end

    it "leaves an all-day item alone either way" do
      midnight = Time.current.in_time_zone(user.timezone).beginning_of_day
      item(name: "Andrew's Bday", all_day: true, start_at: midnight, end_at: midnight + 1.day)

      today = described_class.build(user, conversation)[:today_agenda]

      expect(today.find { |i| i[:title] == "Andrew's Bday" }).not_to have_key(:passed)
    end
  end
end
