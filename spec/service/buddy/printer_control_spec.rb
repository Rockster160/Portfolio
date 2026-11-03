require "rails_helper"

# The printer verbs that aren't about a file (preheat, cool, home), so none of
# them falls through to `print_again` and starts hardware.
RSpec.describe "printer_control" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:tool)   { Buddy::Tools[:printer_control] }
  let(:ctx)    { Buddy::ToolContext.new(user, conversation: convo) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  it "runs the action without choosing a file and reports what the printer said", :aggregate_failures do
    expect(PrinterCommand).to receive(:command).with("preheat").and_return("Pre-heating your printer")

    result = Buddy::Tools.dispatch(tool, { action: :preheat }, ctx)

    expect(result[:ok]).to be(true)
    expect(result[:data][:printer_said]).to eq("Pre-heating your printer")
    expect(tool[:receipt].call(result[:data], ctx)).to eq("Pre-heating your printer")
  end

  it "refuses an action that isn't one of the three" do
    _payload, errors = Buddy::Tools.validate_payload(tool, { action: "print" })

    expect(errors).not_to be_empty
  end

  it "is safe to replay inside a routine, unlike print_again", :aggregate_failures do
    expect(Buddy::Tools.routinable?(tool)).to be(true)
    expect(Buddy::Tools.routinable?(Buddy::Tools[:print_again])).to be(false)
  end
end
