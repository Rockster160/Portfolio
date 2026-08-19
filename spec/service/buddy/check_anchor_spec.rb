require "rails_helper"

# check_anchor is a READ: it resolves the next time and hands it straight back,
# so the model writes its reply holding the actual time. No chip, no second turn.
RSpec.describe "check_anchor tool" do
  let(:user)   { create(:user) }
  let(:tz)     { ActiveSupport::TimeZone[user.timezone] }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
  end

  def read(payload)
    Buddy::GPT::Turn.resolve_tool(
      Buddy::Tools[:check_anchor],
      { call_id: "call_1", name: :check_anchor, arguments: payload },
      user: user, conversation: convo,
    )
  end

  def sunset_at(time, identifier: "today")
    anchor = user.anchors.find_or_create_by!(key: "sun:sunset")
    anchor.set_occurrence(time, identifier: identifier)
    anchor
  end

  it "hands the next time back in the same turn" do
    sunset_at(1.hour.from_now)

    result = read(key: "sun:sunset")

    expect(result[:status]).to eq(:answered)
    expect(result[:anchor]).to eq("sun:sunset")
    expect(result[:next]).to be_present
    expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
  end

  it "applies an offset" do
    at = tz.local(2026, 8, 19, 20, 24)
    travel_to(tz.local(2026, 8, 19, 12, 0)) do
      sunset_at(at)

      expect(read(key: "sun:sunset", offset: "-30m")[:next]).to include("7:54pm")
    end
  end

  it "lists every anchor when given no key" do
    sunset_at(1.hour.from_now)
    user.anchors.create!(key: "trash:pickup").set_occurrence(2.days.from_now, identifier: "wk")

    result = read({})

    expect(result[:anchors].pluck(:anchor)).to contain_exactly("sun:sunset", "trash:pickup")
  end

  # A lookup that didn't come back is NOT an answer — otherwise the model
  # reports a time it never got.
  it "fails rather than inventing one for an unknown anchor" do
    expect(read(key: "moon:rise")[:status]).not_to eq(:answered)
  end

  it "fails when the anchor exists but has nothing upcoming" do
    user.anchors.create!(key: "sun:sunset")

    expect(read(key: "sun:sunset")[:status]).not_to eq(:answered)
  end

  it "fails when they have no anchors at all" do
    expect(read({})[:status]).not_to eq(:answered)
  end

  it "tolerates a key given with an offset already attached" do
    sunset_at(1.hour.from_now)

    expect(read(key: "sun:sunset-5m")[:anchor]).to eq("sun:sunset")
  end
end
