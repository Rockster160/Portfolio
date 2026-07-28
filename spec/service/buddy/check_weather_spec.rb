require "rails_helper"

# check_weather is an AUTO tool: it runs on the spot and drops the reading in
# as an activity chip — no confirmation checklist.
RSpec.describe "check_weather tool" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def run(payload)
    markers = [{ tool_name: :check_weather, payload: payload, span: [0, 0] }]
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  def chip
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
  end

  it "checks home/local weather when no location is given (auto, no checklist)" do
    allow(WeatherService).to receive(:summary)
      .with(lat: WeatherService::HOME_LAT, lng: WeatherService::HOME_LNG)
      .and_return("currently 75°F, clear sky. today high 88°F / low 61°F.")

    result = run({})
    expect(result[:action]).to be_nil
    expect(result[:auto_ran]).to be(true)
    expect(chip.body).to eq("🌤️ home: currently 75°F, clear sky. today high 88°F / low 61°F.")
  end

  it "checks a named saved place via its contact coordinates" do
    contact = user.contacts.create!(name: "The Gym")
    contact.addresses.create!(user: user, street: "1 Fit Way", lat: 40.6, lng: -111.8, primary: true)
    allow(WeatherService).to receive(:summary).with(lat: 40.6, lng: -111.8).and_return("currently 70°F.")

    run(location: "the gym")
    expect(chip.body).to eq("🌤️ The Gym: currently 70°F.")
  end

  it "geocodes a general place that isn't saved anywhere (the Plunge in Alpine)" do
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return([40.45, -111.77])
    allow(WeatherService).to receive(:summary).with(lat: 40.45, lng: -111.77).and_return("currently 66°F.")

    run(location: "the Plunge in Alpine")
    expect(chip.body).to eq("🌤️ the Plunge in Alpine: currently 66°F.")
  end

  it "reports honestly when it can't resolve the place" do
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return(nil)

    run(location: "somewhere imaginary")
    expect(chip.body).to eq("Couldn't pull the weather for somewhere imaginary right now.")
  end
end
