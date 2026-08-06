require "rails_helper"

# check_weather is a READ: it resolves the place, fetches the reading, and hands
# it straight back as the tool's output, so the model writes its reply holding
# the numbers. No chip, no second turn.
RSpec.describe "check_weather tool" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
  end

  def read(payload)
    Buddy::GPT::Turn.resolve_tool(
      Buddy::Tools[:check_weather],
      { call_id: "call_1", name: :check_weather, arguments: payload },
      user: user, conversation: convo,
    )
  end

  it "hands home weather back in the same turn" do
    allow(WeatherService).to receive(:summary)
      .with(lat: WeatherService::HOME_LAT, lng: WeatherService::HOME_LNG)
      .and_return("currently 75°F, clear sky. today high 88°F / low 61°F.")

    result = read({})
    expect(result[:status]).to eq(:answered)
    expect(result[:reading]).to include("currently 75°F")
    expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
  end

  it "resolves a named saved place and reads it there" do
    contact = user.contacts.create!(name: "The Gym")
    contact.addresses.create!(user: user, street: "1 Fit Way", lat: 40.6, lng: -111.8, primary: true)
    allow(WeatherService).to receive(:summary).with(lat: 40.6, lng: -111.8).and_return("currently 70°F.")

    result = read(location: "the gym")
    expect(result[:place]).to eq("The Gym")
    expect(result[:reading]).to include("70°F")
  end

  # A lookup that didn't come back is NOT an answer, so it has to reach the
  # model as a failure — otherwise the model reports weather it never got.
  it "fails outright when it honestly can't resolve the place" do
    allow_any_instance_of(AddressBook).to receive(:geocode).and_return(nil)

    result = read(location: "somewhere imaginary")
    expect(result[:status]).to eq("failed")
    expect(result[:note]).to include("Do not say you did it")
  end
end
