require "rails_helper"

# The agenda that Buddy reads, as Buddy::Context hands it over.
RSpec.describe Buddy::Context, ".build agenda" do
  let(:user)   { create(:user) }
  let(:conversation) { user.byte_conversations.create!(mode: :buddy) }
  let(:agenda) { create(:agenda, user: user) }
  let(:schedule) { create(:agenda_schedule, agenda: agenda) }

  # "Today" is a real window in the user's zone, so an item placed a few hours
  # out lands in TOMORROW when the suite runs late in the evening. Mid-morning
  # keeps every relative offset below on the day the examples mean.
  around { |ex| travel_to(Time.zone.parse("2026-07-15 15:00 UTC")) { ex.run } }

  def item(attrs)
    create(:agenda_item, { agenda: agenda }.merge(attrs))
  end

  def built
    described_class.build(user, conversation)
  end

  def shared_in(permission)
    create(:agenda, user: create(:user)).tap { |a| AgendaShare.create!(agenda: a, user: user, permission: permission) }
  end

  # `passed` reads the END of an event (a task has no span, so its start), and
  # an all-day item is never passed. The context carries the short form of a
  # place, not the mailing address.
  it "hands over today's items with cadence, drive time, short place and passed flag", :aggregate_failures do
    monthly  = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "monthly" })
    midnight = Time.current.in_time_zone(user.timezone).beginning_of_day
    item(name: "Vet appt", start_at: Time.current + 3.hours)
    item(name: "Standup", start_at: Time.current + 2.hours, agenda_schedule: schedule)
    item(name: "1:1 with Eric", start_at: Time.current + 2.hours, agenda_schedule: monthly)
    item(name: "Offsite", start_at: Time.current + 3.hours, metadata: { "travel" => { "travel_minutes" => 25 } })
    item(name: "Lunch", start_at: Time.current + 2.hours, location: "The Rose Establishment")
    item(name: "Hair trim", start_at: 2.hours.from_now, location: "1234 E 9400 S, Sandy, UT 84070")
    item(name: "Heads-down", kind: :event, start_at: Time.current - 30.minutes, end_at: Time.current + 8.hours)
    item(name: "Early sync", kind: :event, start_at: Time.current - 2.hours, end_at: Time.current - 90.minutes)
    item(name: "Call the vet", start_at: Time.current - 10.minutes)
    item(name: "Marcos Jones's birthday", all_day: true, start_at: midnight, end_at: midnight + 1.day)

    today = built[:today_agenda].index_by { |i| i[:title] }

    expect(today["Vet appt"][:cadence]).to be_nil
    expect(today["Standup"][:cadence]).to eq("daily")
    expect(today["1:1 with Eric"][:cadence]).to eq("monthly")
    expect(today["Offsite"][:drive_min]).to eq(25)
    expect(today["Lunch"][:where]).to eq("The Rose Establishment")
    expect(today["Hair trim"][:where]).to eq("Sandy")

    expect(today["Heads-down"]).not_to have_key(:passed)
    expect(today["Early sync"][:passed]).to be(true)
    expect(today["Call the vet"][:passed]).to be(true)

    # Everything in today_agenda IS today, so an all-day item says so rather
    # than reading as a duration.
    expect(today["Marcos Jones's birthday"]).to include(time: "today", all_day: true)
    expect(today["Marcos Jones's birthday"]).not_to have_key(:passed)
  end

  # An all-day event is stored at the LOCAL midnight of its date, so a today
  # window of `now .. now+24h` would pull tomorrow's into today. A cancelled
  # routine is a heads-up; a cancelled one-off is noise.
  it "hands over the rest of the week by day, with place, all-day tomorrows and cancelled routines", :aggregate_failures do
    tomorrow_midnight = Time.current.in_time_zone(user.timezone).beginning_of_day + 1.day
    item(name: "Dentist", start_at: Time.current + 3.days)
    item(name: "Today thing", start_at: Time.current)
    item(name: "Pickup B and Saya", start_at: Time.current + 5.days, location: "airport")
    item(name: "Plunge with Wil", start_at: 5.days.from_now, location: "Horsetail Falls, Alpine, UT")
    item(name: "Andrew's Bday", all_day: true, start_at: tomorrow_midnight, end_at: tomorrow_midnight + 1.day)
    item(name: "No standup", start_at: Time.current + 1.day, agenda_schedule: schedule, status: :cancelled)
    item(name: "Dropped", start_at: Time.current + 2.days, status: :cancelled)

    context  = built
    upcoming = context[:upcoming_agenda].index_by { |i| i[:title] }

    expect(upcoming["Dentist"][:day]).to be_present
    expect(upcoming["Dentist"]).not_to have_key(:where)
    expect(upcoming).not_to have_key("Today thing")
    expect(upcoming["Pickup B and Saya"][:where]).to eq("airport")
    expect(upcoming["Plunge with Wil"][:where]).to eq("Horsetail Falls")

    expect(context[:today_agenda].pluck(:title)).not_to include("Andrew's Bday")
    expect(upcoming["Andrew's Bday"]).to include(day: "tomorrow", time: "all day")

    expect(upcoming["No standup"][:cancelled]).to be(true)
    expect(upcoming).not_to have_key("Dropped")
  end

  # The briefing is handed only the items that make the day unlike any other;
  # a direct question about the calendar still gets the whole thing. A normal
  # thing missing beats a normal thing present.
  it "gives the briefing a notable-only view of today and the week, leaving the full lists in place", :aggregate_failures do
    weekdays = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "weekdays" })
    monthly  = create(:agenda_schedule, agenda: agenda, recurrence: { "freq" => "monthly" })
    item(name: "Standup", start_at: Time.current + 1.hour, agenda_schedule: weekdays)
    item(name: "Launch Readiness", start_at: Time.current + 3.hours)
    item(name: "One on one", start_at: Time.current + 2.hours, agenda_schedule: monthly)
    item(name: "Planning", start_at: Time.current + 4.hours, agenda_schedule: weekdays, status: :cancelled)
    item(name: "Later standup", start_at: Time.current + 2.days, agenda_schedule: weekdays)
    item(name: "Dentist", start_at: Time.current + 2.days)

    context = built

    expect(context[:today_notable].pluck(:title)).to include("Launch Readiness", "One on one", "Planning")
    expect(context[:today_notable].pluck(:title)).not_to include("Standup")
    expect(context[:upcoming_notable].pluck(:title)).to include("Dentist")
    expect(context[:upcoming_notable].pluck(:title)).not_to include("Later standup")
    expect(context[:today_agenda].pluck(:title)).to include("Standup")
  end

  describe "an interview's two rows" do
    let(:at) { Time.current + 2.hours }
    let(:invites) { create(:agenda, user: user) }

    def note_row(company, start_at: at)
      row = item(name: "Interview: #{company}", start_at: start_at)
      job = JobApplication.create!(user: user, company: company, color: "#388bfd", status: :active)
      note = job.notes.create!(body: "Booked", occurred_at: Time.current)
      note.update_columns(agenda_item_id: row.id)
      row
    end

    def invite(name, start_at: at)
      create(:agenda_item, agenda: invites, name: name, start_at: start_at, external_uid: SecureRandom.hex(6))
    end

    it "names it once, by the job note's row, today and later in the week" do
      note_row("Neighbor")
      invite("Onsite Interview with Neighbor")
      note_row("Acme", start_at: at + 2.days)
      invite("Onsite Interview with Acme", start_at: at + 2.days)

      context = built
      expect(context[:today_agenda].pluck(:title)).to eq(["Interview: Neighbor"])
      expect(context[:upcoming_agenda].pluck(:title)).to eq(["Interview: Acme"])
    end

    it "keeps an invite at another minute, from another company, or an unsynced row sharing the minute" do
      note_row("Neighbor")
      invite("Onsite Interview with Neighbor", start_at: at + 30.minutes)
      invite("Call with iCapital")
      item(name: "Neighbor prep", start_at: at)

      expect(built[:today_agenda].pluck(:title)).to contain_exactly(
        "Interview: Neighbor", "Onsite Interview with Neighbor", "Call with iCapital", "Neighbor prep"
      )
    end
  end

  # A share at :owner means the calendar is theirs too (Agenda#owned_by?); only
  # :owner carries co-ownership, so :editor and :viewer stay at arm's length.
  it "tags a partner's viewer- or editor-shared item as not theirs, and an owned or co-owned one as theirs", :aggregate_failures do
    viewer = shared_in(:viewer)
    create(:agenda_item, agenda: viewer, name: "Partner Ortho", start_at: Time.current + 2.hours)
    create(:agenda_item, agenda: shared_in(:editor), name: "Their Thing", start_at: Time.current + 2.hours)
    create(:agenda_item, agenda: shared_in(:owner), name: "Dinner", start_at: Time.current + 2.hours)
    item(name: "My Standup", start_at: Time.current + 1.hour)

    today = built[:today_agenda].index_by { |i| i[:title] }

    expect(today["Partner Ortho"][:mine]).to be(false)
    expect(today["Partner Ortho"][:owner]).to eq(viewer.user.first_name)
    expect(today["Their Thing"][:mine]).to be(false)
    expect(today["Dinner"]).not_to have_key(:mine)
    expect(today["Dinner"]).not_to have_key(:owner)
    expect(today["My Standup"]).not_to have_key(:mine)
  end

  # A partner's item is awareness, so the clash with one of theirs is what's
  # worth carrying; it is computed here because this layer holds real times.
  describe "a partner's item that runs into one of theirs" do
    let(:hers) { shared_in(:viewer) }

    it "marks only the partner's item that overlaps one of theirs", :aggregate_failures do
      item(name: "My Standup", start_at: Time.current + 1.hour, end_at: Time.current + 2.hours)
      item(name: "My Other",   start_at: Time.current + 90.minutes, end_at: Time.current + 150.minutes)
      create(:agenda_item, agenda: hers, name: "Her Ortho",
             start_at: Time.current + 90.minutes, end_at: Time.current + 150.minutes)
      create(:agenda_item, agenda: hers, name: "Her Yoga",
             start_at: Time.current + 4.hours, end_at: Time.current + 5.hours)

      today = built[:today_agenda].index_by { |i| i[:title] }

      expect(today["Her Ortho"][:collides_with]).to eq("My Standup")
      expect(today["Her Yoga"]).not_to have_key(:collides_with)
      expect(today["My Standup"]).not_to have_key(:collides_with)
      expect(today["My Other"]).not_to have_key(:collides_with)
    end

    # An all-day item would otherwise run into everything.
    it "does not let an all-day item collide with the day" do
      item(name: "My Standup", start_at: Time.current.beginning_of_day, all_day: true)
      create(:agenda_item, agenda: hers, name: "Her Ortho",
             start_at: Time.current + 90.minutes, end_at: Time.current + 150.minutes)

      expect(built[:today_agenda].find { |i| i[:title] == "Her Ortho" }).not_to have_key(:collides_with)
    end
  end

  # Every screen in the app honours the agenda filters, so Buddy does too.
  it "leaves out hidden series, one-offs and calendars, and nothing else", :aggregate_failures do
    series = create(:agenda_schedule, agenda: user.agendas.first, name: "Marcos' Birthday")
    item(name: "Marcos' Birthday", start_at: Time.current + 2.hours, agenda_schedule: series)
    hidden = item(name: "Dentist", start_at: Time.current + 2.hours)
    item(name: "Tech Retro", start_at: Time.current + 3.hours)
    other = create(:agenda, user: user)
    create(:agenda_item, agenda: other, name: "Payday", all_day: true, start_at: (Date.current + 2).beginning_of_day)

    expect(built[:today_agenda].pluck(:title)).to include("Marcos' Birthday", "Dentist")

    AgendaPreference.for(user).update!(
      hidden_schedule_ids: [series.id], hidden_item_ids: [hidden.id], hidden_agenda_ids: [other.id],
    )
    context = built

    expect(context[:today_agenda].pluck(:title)).to include("Tech Retro")
    expect(context[:today_agenda].pluck(:title)).not_to include("Marcos' Birthday", "Dentist")
    expect(context[:upcoming_agenda].pluck(:title)).not_to include("Payday")
  end

  # The same person's birthday on two of their own calendars is one thing. A
  # timed thing on two calendars is two commitments until something says
  # otherwise, so an all-day is the only shape this folds.
  it "folds one all-day thing on two calendars into one, and nothing else", :aggregate_failures do
    other = create(:agenda, user: user)
    day   = Date.current + 2
    at    = day.beginning_of_day + 9.hours
    item(name: "Marcos' Birthday", start_at: day.beginning_of_day, all_day: true)
    create(:agenda_item, agenda: other, name: "Marcos Jones's Birthday", start_at: day.beginning_of_day, all_day: true)
    create(:agenda_item, agenda: other, name: "Trash Day", start_at: day.beginning_of_day, all_day: true)
    item(name: "Pat's Birthday", start_at: day.beginning_of_day, all_day: true)
    create(:agenda_item, agenda: other, name: "Pat's Birthday", start_at: (day + 1).beginning_of_day, all_day: true)
    item(name: "Standup", start_at: at, end_at: at + 30.minutes)
    create(:agenda_item, agenda: other, name: "Standup", start_at: at, end_at: at + 30.minutes)

    titles = built[:upcoming_agenda].pluck(:title)

    expect(titles.grep(/Marcos/)).to eq(["Marcos' Birthday"])
    expect(titles).to include("Trash Day")
    expect(titles.grep(/Pat's/).length).to eq(2)
    expect(titles.grep(/Standup/).length).to eq(2)
  end

  # A departure time on a viewer's copy of somebody else's calendar is an
  # instruction to go to their appointment, so it stops reaching the model;
  # their ARRIVAL HOME is a fact about this person's evening and stays. A joint
  # calendar is one they both leave for.
  it "keeps departures on their own and co-owned items, drops them off a viewer's and a no-drive item", :aggregate_failures do
    # The chain recomputes a located event on commit; what's pinned is the READ.
    allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
    travel = { "travel" => { "travel_minutes" => 27, "leave_at" => (Time.current + 2.hours).to_i } }
    viewer = shared_in(:viewer)
    mine   = user.agendas.first || create(:agenda, user: user)

    create(:agenda_item, agenda: mine, name: "My Drive", start_at: Time.current + 3.hours, metadata: travel)
    create(:agenda_item, agenda: shared_in(:owner), name: "Dinner Out", start_at: Time.current + 3.hours, metadata: travel)
    create(:agenda_item, agenda: viewer, name: "Her Board Meeting", start_at: Time.current + 3.hours, metadata: travel)
    create(
      :agenda_item, agenda: mine, name: "Breakfast At Home", start_at: 3.hours.from_now,
      metadata: { "travel" => { "travel_minutes" => 0, "travel_from_kind" => "home", "leave_at" => 3.hours.from_now.to_i } }
    )
    create(
      :agenda_item, agenda: viewer, name: "Her Yoga", kind: :event, location: "Mountain Yoga Sandy",
      start_at: 3.hours.from_now, end_at: 4.hours.from_now,
      metadata: {
        "travel" => {
          "travel_minutes"      => 27,
          "leave_at"            => 2.hours.from_now.to_i,
          "post_travel_seconds" => 1860,
          "post_travel_minutes" => 31,
        },
      }
    )

    today = built[:today_agenda].index_by { |i| i[:title] }

    expect(today["My Drive"]).to include(:leave_by, :drive_min)
    expect(today["Dinner Out"]).to include(:leave_by, :drive_min)
    expect(today["Breakfast At Home"]).not_to include(:leave_by, :drive_min)
    expect(today["Her Board Meeting"]).not_to include(:leave_by, :drive_min)
    expect(today["Her Board Meeting"]).to include(mine: false, owner: viewer.user.first_name)
    expect(today["Her Yoga"]).not_to include(:leave_by)
    expect(today["Her Yoga"][:home_by]).to eq(Buddy::Clock.at(4.hours.from_now.advance(minutes: 31), zone: user.timezone))
    expect(today["Her Yoga"][:drive_home_min]).to eq(31)
  end
end
