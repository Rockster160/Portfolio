require "rails_helper"

# Rocco, 2026-09-14: "Buddy should be able to access my location and subscribe
# to listening for location changes so that he can act on things like
# arrive/depart." The subscribing half already existed - `remind_when` has taken
# a coordinate-matched travel watch since July - and this is the other half: the
# question answered about NOW rather than about a movement.
#
# A READ, like check_weather: it resolves, reads and hands the answer straight
# back in the same turn, so the model writes its reply holding the facts.
RSpec.describe "check_location tool" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:home)   { [40.48049, -111.99816] }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
    allow(user).to receive(:me?).and_return(true)
    # An allow-list, so a feature added this month is off for everyone until
    # it is granted - the owner's own account needs the same grant in prod.
    user.update!(buddy_features: Buddy::Features.all)
    place!("Home", home)
  end

  def place!(name, coord)
    contact = user.contacts.create!(name: name)
    contact.addresses.create!(user: user, street: "#{name} St", lat: coord[0], lng: coord[1], primary: true)
    contact
  end

  # `at` is stored in MILLISECONDS - Tesla sends ms since epoch and
  # LocationCache.set matched it rather than converting on the way in.
  def reported!(coord, name: "Home", ago: 2.minutes)
    stamp = ((Time.current - ago).to_f * 1000).round
    allow(::LocationCache).to receive(:last_location).and_return({ loc: coord, at: stamp, name: name })
    allow(::LocationCache).to receive(:last_coord).and_return(coord)
    allow(::LocationCache).to receive(:at_home?) { |c| c.present? && (c[0] - home[0]).abs < 0.001 }
    allow(::LocationCache).to receive(:driving?).and_return(false)
  end

  def read(payload = {})
    Buddy::GPT::Turn.resolve_tool(
      Buddy::Tools[:check_location],
      { call_id: "call_1", name: :check_location, arguments: payload },
      user: user, conversation: convo,
    )
  end

  it "answers where they are, in the same turn" do
    reported!(home)

    result = read
    expect(result[:status]).to eq(:answered)
    expect(result[:where]).to eq("Home")
    expect(result[:at_home]).to be(true)
    expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
  end

  it "says when they are somewhere else" do
    reported!([40.7608, -111.8910], name: "Salt Lake City")

    expect(read[:where]).to eq("Salt Lake City")
    expect(read[:at_home]).to be(false)
  end

  it "carries whether they are driving" do
    reported!(home)
    allow(::LocationCache).to receive(:driving?).and_return(true)

    expect(read[:driving]).to be(true)
  end

  # A position is only as fresh as the last thing that reported one, and the
  # description asks the model to say so when it is stale. That judgement needs
  # a NUMBER - "a while ago" is not something it can make it from.
  it "says how old the reading is" do
    reported!(home, ago: 4.hours)

    expect(read[:minutes_ago]).to be_within(1).of(240)
  end

  describe "asked about one place in particular" do
    # The name the cache carries and the name they used are routinely different
    # words for the same spot, so the comparison has to happen here rather than
    # being left for the model to guess at.
    it "answers that question rather than handing back a name" do
      reported!(home)

      result = read(place: "home")
      expect(result[:asked_about]).to eq("home")
      expect(result[:at_that_place]).to be(true)
    end

    it "says no when they are not there" do
      place!("The Gym", [40.6, -111.8])
      reported!(home)

      expect(read(place: "the gym")[:at_that_place]).to be(false)
    end

    it "resolves the way a person says a place" do
      place!("Chelsea", [40.6, -111.8])
      reported!([40.6, -111.8], name: "Chelsea")

      expect(read(place: "Chelsea's place")[:at_that_place]).to be(true)
    end

    it "fails rather than guessing at somewhere it has never heard of" do
      reported!(home)

      expect(read(place: "Narnia")[:status]).not_to eq(:answered)
    end
  end

  # Not an error and not a refusal - there is a real sentence to say, and it is
  # not "you're at home".
  it "reports plainly that nothing has come in yet" do
    allow(::LocationCache).to receive(:last_location).and_return(nil)
    allow(::LocationCache).to receive(:last_coord).and_return(nil)

    expect(read[:status]).not_to eq(:answered)
  end

  # LocationCache is User.me's and there is no per-user one, so an ungated
  # version of this answers Chelsea with Rocco's position. Gated twice: the
  # feature is OWNER_ONLY, and the tool asks again at run time.
  it "refuses anybody but the owner" do
    reported!(home)
    allow(user).to receive(:me?).and_return(false)

    expect(read[:status]).not_to eq(:answered)
  end

  it "is not offered to anybody but the owner" do
    expect(Buddy::Features::OWNER_ONLY).to include(:location)
    expect(Buddy::Features::DEFAULT).not_to include(:location)
  end
end
