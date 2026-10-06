require "rails_helper"

RSpec.describe Jarvis::Log do
  let(:user) { FactoryBot.create(:user) }

  before { allow(::Jil).to receive(:trigger) }

  # The meal builder backdates a meal by spelling the time out in full.
  it "logs a backdated meal at that local time and confirms it in local time" do
    travel_to(Time.find_zone("America/Denver").parse("2026-10-06 14:00")) {
      reply = described_class.attempt(user, "log Food Apple, Toast x2 (300) on October 5, 2026 at 7:05pm")

      event = ActionEvent.where(user: user).last
      expect(event.name).to eq("Food")
      expect(event.notes).to eq("Apple, Toast x2 (300)")
      expect(event.timestamp.in_time_zone("America/Denver").to_fs(:short_time)).to eq("7:05 PM")
      expect(event.timestamp.in_time_zone("America/Denver").to_date).to eq(Date.new(2026, 10, 5))
      expect(reply).to eq("Logged Food (Apple, Toast x2 (300)) [Yesterday 7:05 PM]")
    }
  end

  it "leaves a meal without a time at now" do
    reply = described_class.attempt(user, "log Food Apple (95)")

    expect(ActionEvent.where(user: user).last.notes).to eq("Apple (95)")
    expect(reply).to eq("Logged Food (Apple (95))")
  end
end
