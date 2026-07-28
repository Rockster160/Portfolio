require "rails_helper"

# Regression: proposal payloads are JSON-serialized onto the ByteAction between
# build and execute, so at execute time `at` is an ISO STRING and `duration` a
# number. The agenda tools used to do `string_at + duration.minutes` (→
# "no implicit conversion of ActiveSupport::Duration into String") and wrote to
# a non-existent `title` column. These specs feed the execute-time shape.
RSpec.describe "agenda tools (execute-time string payloads)" do
  let(:user)    { create(:user) }
  let!(:agenda) { create(:agenda, user: user) }
  let(:ctx)     { Buddy::ToolContext.new(user) }

  # Setting a location kicks off the travel-chain geocode (that's what powers
  # drive time). Stub it so the unit test doesn't hit Google Maps.
  before { allow_any_instance_of(AgendaItem).to receive(:enqueue_travel_chain_sync) }

  it "add_agenda_item parses the ISO time, sets duration, writes name" do
    tool = Buddy::Tools[:add_agenda_item]
    at   = 2.hours.from_now.change(sec: 0).iso8601
    payload = { agenda_id: agenda.id, title: "Coffee with Katie", at: at, duration: 30, kind: "event" }

    result = tool[:execute].call(payload, ctx)
    item = AgendaItem.find(result[:agenda_item_id])

    expect(item.name).to eq("Coffee with Katie")
    expect(item.start_at).to be_within(1.second).of(Time.zone.parse(at))
    expect(item.end_at).to   be_within(1.second).of(Time.zone.parse(at) + 30.minutes)
  end

  it "add_agenda_item captures a separate location + defaults to a 5-min early arrival" do
    tool = Buddy::Tools[:add_agenda_item]
    at   = 2.hours.from_now.change(sec: 0).iso8601
    payload = { agenda_id: agenda.id, title: "Coffee", at: at, duration: 30, location: "Lucky Ones", kind: "event" }

    result = tool[:execute].call(payload, ctx)
    item = AgendaItem.find(result[:agenda_item_id])

    expect(item.name).to eq("Coffee")
    expect(item.location).to eq("Lucky Ones")
    expect(item.arrive_early_minutes).to eq(5)
  end

  it "add_agenda_item targets a named calendar (fuzzy 'our' -> 'Ours'), defaulting otherwise" do
    ours = create(:agenda, user: user, name: "Ours 💕")

    expect(ctx.resolve_writable_agenda("our schedule")).to eq(ours)
    expect(ctx.resolve_writable_agenda("ours")).to eq(ours)
    # Blank → the primary local agenda (lowest id among writable), not "Ours".
    primary = user.editable_agendas.reject(&:managed_externally?).min_by(&:id)
    expect(ctx.resolve_writable_agenda(nil)).to eq(primary)
    expect(ctx.resolve_writable_agenda(nil)).not_to eq(ours)

    tool   = Buddy::Tools[:add_agenda_item]
    result = tool[:confirm].call({ title: "Plunge", calendar: "our" }, ctx)
    expect(result[:resolved][:agenda_id]).to eq(ours.id)
    expect(result[:summary]).to include("Ours")
  end

  it "add_agenda_item label: one non-default detail per line, symbols not word-labels" do
    tool = Buddy::Tools[:add_agenda_item]
    payload = {
      title: "Plunge", at: 2.hours.from_now, duration: 120,
      location: "Horsetail Falls, Alpine, UT", agenda_name: "Ours 💕", agenda_default: false,
    }

    out   = tool[:label].call(payload, ctx)
    lines = out[:sub].split("\n")

    expect(out[:title]).to eq("Plunge")
    expect(lines[0]).to match(/\d{1,2}:\d\d [AP]M–\d{1,2}:\d\d [AP]M/)  # when, as a range
    expect(lines).to include("@ Horsetail Falls, Alpine, UT")          # location, own line
    expect(lines).to include("📅 Ours 💕")                             # non-default calendar, own line
  end

  it "add_agenda_item label omits the calendar line when it's the default, and skips absent details" do
    tool = Buddy::Tools[:add_agenda_item]
    payload = { title: "Dentist", at: 2.hours.from_now, duration: 30, agenda_name: "Rockster160", agenda_default: true }

    out = tool[:label].call(payload, ctx)

    expect(out[:sub]).not_to include("Rockster160")  # default calendar → no line
    expect(out[:sub]).not_to include("@")            # no location → no @ line
  end

  it "add_agenda_item honors a passed duration (e.g. a 2-hour plunge, not 30m)" do
    tool = Buddy::Tools[:add_agenda_item]
    at   = 2.hours.from_now.change(sec: 0).iso8601
    payload = { agenda_id: agenda.id, title: "Plunge", at: at, duration: 120, kind: "event" }

    result = tool[:execute].call(payload, ctx)
    item = AgendaItem.find(result[:agenda_item_id])
    expect(item.kind).to eq("event")
    expect(item.end_at).to be_within(1.second).of(Time.zone.parse(at) + 120.minutes)
  end

  it "add_agenda_item leaves the arrival buffer at the default (0) when there's no location" do
    tool = Buddy::Tools[:add_agenda_item]
    at   = 2.hours.from_now.change(sec: 0).iso8601
    payload = { agenda_id: agenda.id, title: "Dentist", at: at, duration: 30, kind: "event" }

    result = tool[:execute].call(payload, ctx)
    expect(AgendaItem.find(result[:agenda_item_id]).arrive_early_minutes).to eq(0)
  end

  it "edit_agenda_item retitles + reschedules + resizes from string payload" do
    item = agenda.agenda_items.create!(
      name: "Old", start_at: 1.day.from_now, end_at: 1.day.from_now + 30.minutes, kind: :event, status: :confirmed,
    )
    tool   = Buddy::Tools[:edit_agenda_item]
    new_at = 2.days.from_now.change(sec: 0).iso8601
    payload = { agenda_item_id: item.id, title: "New name", at: new_at, duration: 45 }

    tool[:execute].call(payload, ctx)
    item.reload

    expect(item.name).to eq("New name")
    expect(item.start_at).to be_within(1.second).of(Time.zone.parse(new_at))
    expect(item.end_at).to   be_within(1.second).of(Time.zone.parse(new_at) + 45.minutes)
  end

  it "resolve_agenda_item matches on name (LOWER(name), not the missing title column)" do
    agenda.agenda_items.create!(name: "Dentist", start_at: 1.day.from_now, end_at: 1.day.from_now + 30.minutes, kind: :event, status: :confirmed)
    expect(ctx.resolve_agenda_item("dentist")&.name).to eq("Dentist")
  end
end
