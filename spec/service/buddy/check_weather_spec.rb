require "rails_helper"

# check_weather is an AUTO tool: it runs on the spot, fetches the reading, and
# feeds it BACK into a fresh Buddy turn so Buddy relays it in its own words —
# no raw activity chip. Only a genuine failure drops a chip.
RSpec.describe "check_weather tool" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
  end

  def run(payload)
    markers = [{ tool_name: :check_weather, payload: payload, span: [0, 0] }]
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  def chip
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
  end

  it "relays home weather via a follow-up reply, not a raw chip" do
    allow(WeatherService).to receive(:summary)
      .with(lat: WeatherService::HOME_LAT, lng: WeatherService::HOME_LNG)
      .and_return("currently 75°F, clear sky. today high 88°F / low 61°F.")

    result = run({})
    expect(result[:action]).to be_nil
    expect(chip).to be_nil # no raw activity chip
    expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt)
      .with(hash_including(user: user, seed: include("currently 75°F")))
  end

  it "resolves a named saved place and relays its reading" do
    contact = user.contacts.create!(name: "The Gym")
    contact.addresses.create!(user: user, street: "1 Fit Way", lat: 40.6, lng: -111.8, primary: true)
    allow(WeatherService).to receive(:summary).with(lat: 40.6, lng: -111.8).and_return("currently 70°F.")

    run(location: "the gym")
    expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt)
      .with(hash_including(seed: include("The Gym").and(include("70°F"))))
    expect(chip).to be_nil
  end

  it "still drops a chip when it honestly can't resolve the place" do
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return(nil)

    run(location: "somewhere imaginary")
    expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
    expect(chip.body).to include("Couldn't pull the weather for somewhere imaginary right now.")
  end
end
