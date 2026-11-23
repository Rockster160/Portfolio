require "rails_helper"

# count_days is a READ: the number comes back in the same turn, worked out from
# the person's own today rather than in the model's head.
RSpec.describe "count_days tool" do
  let(:user)   { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  def count(payload)
    Buddy::GPT::Turn.resolve_tool(
      Buddy::Tools[:count_days],
      { call_id: "call_1", name: :count_days, arguments: payload },
      user: user, conversation: convo,
    )
  end

  it "counts the days until a date from their own today" do
    result = travel_to(Time.zone.parse("2026-11-23 16:00 UTC")) { count(date: "2027-05-31") }

    expect(result).to include(status: :answered, days: 189, counted: :until, date: "Monday 31 May 2027")
  end

  it "is still yesterday's count in the small hours, before their day turns over" do
    result = travel_to(Time.zone.parse("2026-11-24 08:30 UTC")) { count(date: "2027-05-31") }

    expect(result).to include(days: 189, today: "Monday 23 November 2026")
  end

  it "counts the days since a date that has passed" do
    result = travel_to(Time.zone.parse("2026-11-23 16:00 UTC")) { count(date: "2026-11-01") }

    expect(result).to include(days: 22, counted: :since)
  end

  it "fails outright on something that isn't a date" do
    expect(count(date: "Memorial Day")[:status]).to eq("failed")
  end
end
