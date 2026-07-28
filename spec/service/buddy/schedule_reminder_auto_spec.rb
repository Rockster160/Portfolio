require "rails_helper"

# schedule_reminder is now an AUTO tool: no confirmation checkbox, it runs on
# the spot and drops an activity-receipt chip.
RSpec.describe "schedule_reminder auto-run" do
  let(:user)  { create(:user) }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }
  let(:msg)   { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  it "creates the reminder + a receipt chip, and NO checklist" do
    at = 2.hours.from_now.in_time_zone(user.timezone).iso8601
    markers = [{ tool_name: :schedule_reminder, payload: { text: "check the oven", at: at }, span: [0, 0] }]

    result = nil
    expect {
      result = Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
    }.to change { BuddyReminder.where(user: user).count }.by(1)

    expect(result[:action]).to be_nil          # no confirmation checklist
    expect(result[:auto_ran]).to be(true)

    chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
    expect(chip).to be_present
    expect(chip.body).to match(/\A(Byte|Moss) will send you a reminder /)
  end

  describe "friendly_future phrasing" do
    let(:ctx) { Buddy::ToolContext.new(user) }
    let(:noon) { Time.current.in_time_zone(user.timezone).change(hour: 18, min: 1) }

    it "gives a bare time for today" do
      expect(ctx.friendly_future(noon)).to eq("at 6:01pm")
    end

    it "prefixes tomorrow / weekday for later days" do
      expect(ctx.friendly_future(noon + 1.day)).to start_with("tomorrow at ")
      expect(ctx.friendly_future(noon + 3.days)).to match(/\Athis \w+ at /)
    end

    it "drops :00 on the hour" do
      on_hour = Time.current.in_time_zone(user.timezone).change(hour: 18, min: 0)
      expect(ctx.friendly_future(on_hour)).to eq("at 6pm")
    end
  end
end
