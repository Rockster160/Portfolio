require "rails_helper"

# Prod 3255. The morning after a one-off reminder rang at 7:00 PM, Suki said
# "the swimming lesson schedule reminder is set for this evening" — the same
# reminder, re-dated a day forward, announced as still coming.
#
# Nothing lied to her. `fired_at` was set, so the row left `pending` and left
# `upcoming_reminders` with it, and the only remaining trace of that reminder
# anywhere the model could see was the conversation itself. A transcript says a
# reminder exists and says nothing about which day, so read as a source it is
# permanently about the future.
#
# An absence can't contradict anything. So a one-off that fired stays visible
# for two days, marked as finished rather than upcoming.
RSpec.describe "Buddy context: a reminder that already rang" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def reminder!(body:, fire_at:, **attrs)
    BuddyReminder.create!(user: user, byte_conversation: convo, body: body, fire_at: fire_at, **attrs)
  end

  def reminders
    Buddy::Context.build(user, convo)[:upcoming_reminders]
  end

  def find(body)
    reminders.find { |r| r[:body].to_s.include?(body) }
  end

  it "keeps a one-off that fired last night in view" do
    reminder!(body: "Check the swim schedule", fire_at: 14.hours.ago, fired_at: 14.hours.ago)

    expect(find("swim schedule")).to be_present
  end

  # The whole point: visible AND unmistakably done. Visible-but-undated would
  # reproduce the bug with an extra step.
  it "marks it finished rather than letting it read as upcoming" do
    reminder!(body: "Check the swim schedule", fire_at: 14.hours.ago, fired_at: 14.hours.ago)

    row = find("swim schedule")
    expect(row[:status]).to eq(:already_rang)
    expect(row[:rang]).to be_present
    expect(row).not_to have_key(:fire_at)
  end

  it "lets go of one that rang last week" do
    reminder!(body: "Old news", fire_at: 8.days.ago, fired_at: 8.days.ago)

    expect(find("Old news")).to be_nil
  end

  it "leaves a pending one exactly as it was" do
    reminder!(body: "Vet appt", fire_at: 2.hours.from_now)

    row = find("Vet appt")
    expect(row[:fire_at]).to be_present
    expect(row[:status]).to be_nil
  end

  # A recurring reminder never sets `fired_at` — it rolls `fire_at` forward and
  # reports `last_fired`, which is a different fix for a different shape of the
  # same lie. It must not also show up here as finished.
  it "does not double-list a recurring one that rolled forward" do
    reminder!(
      body: "Water the flower bed", fire_at: 22.hours.from_now, last_fired_at: 2.hours.ago,
      recurrence: { "kind" => "daily", "at" => "08:00" }
    )

    rows = reminders.select { |r| r[:body].to_s.include?("flower bed") }
    expect(rows.length).to eq(1)
    expect(rows.first[:last_fired]).to be_present
  end

  it "leaves a cancelled one to the off list rather than calling it rung" do
    reminder!(body: "Nevermind this", fire_at: 3.hours.ago, cancelled_at: 4.hours.ago)

    expect(find("Nevermind this")[:status]).to eq(:off)
  end

  # The section is only useful if the model is told what the marker means, and
  # "already delivered" is the one reading that has to be impossible to miss.
  it "tells the model that one of these is not coming" do
    expect(Buddy::Personality.for(user, conversation: convo)).to include("`status: already_rang`")
  end
end
