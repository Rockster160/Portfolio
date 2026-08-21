require "rails_helper"

# Prod 4164: "preheat printer" reached `print_again` with no `file` — which
# means "the last thing printed" — and started a 40-minute vase that had to be
# cancelled at the machine. The printer verbs that aren't about a file needed a
# tool of their own; without one, the nearest match started hardware.
RSpec.describe "printer_control" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:tool)   { Buddy::Tools[:printer_control] }
  let(:ctx)    { Buddy::ToolContext.new(user, conversation: convo) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  it "is registered and offered as a real tool" do
    expect(tool).to be_present
    expect(tool[:args][:action][:values]).to eq(%i[preheat cool home])
  end

  it "warms the printer without choosing a file" do
    expect(PrinterCommand).to receive(:command).with("preheat").and_return("Pre-heating your printer")

    result = Buddy::Tools.dispatch(tool, { action: :preheat }, ctx)

    expect(result[:ok]).to be(true)
    expect(result[:data][:printer_said]).to eq("Pre-heating your printer")
  end

  it "reports back what the printer said, rather than what it hoped" do
    allow(PrinterCommand).to receive(:command).and_return("Cooling your printer")

    result = Buddy::Tools.dispatch(tool, { action: :cool }, ctx)

    expect(tool[:receipt].call(result[:data], ctx)).to eq("Cooling your printer")
  end

  it "refuses an action that isn't one of the three" do
    _payload, errors = Buddy::Tools.validate_payload(tool, { action: "print" })

    expect(errors).not_to be_empty
  end

  # The other half of the incident: the tool that DOES start a job now says it
  # is for reprints only, so an unrecognised printer verb has somewhere else to
  # land instead of falling through to "the last thing printed".
  it "leaves print_again saying it is reprints only" do
    expect(Buddy::Tools[:print_again][:description]).to include("REPRINTS ONLY")
    expect(Buddy::Tools[:print_again][:description]).to include("printer_control")
  end

  it "is safe to replay inside a routine, unlike print_again" do
    expect(Buddy::Tools.routinable?(tool)).to be(true)
    expect(Buddy::Tools.routinable?(Buddy::Tools[:print_again])).to be(false)
  end
end
