require "rails_helper"

RSpec.describe "edit_event tool" do
  let(:user) { create(:user) }
  let(:ctx) { Buddy::ToolContext.new(user) }
  let(:tool) { Buddy::Tools[:edit_event] }
  let!(:event) { ActionEvent.create!(user: user, name: "Sick", timestamp: Time.current) }

  before { allow(ActionEventNotifier).to receive(:notify) }

  # The proposal is stored as JSON and run from there, so the new time is a
  # string by the time it executes.
  it "moves it to a time given as stored text" do
    at = 2.days.ago.change(hour: 8, min: 0, sec: 0)
    payload = { id: event.id, at: at.iso8601 }
    payload.merge!(tool[:confirm].call(payload, ctx)[:resolved])

    expect(tool[:label].call(payload, ctx)[:sub]).to start_with("time →")
    tool[:execute].call(payload, ctx)
    expect(event.reload.timestamp).to eq(at)
  end
end
