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
