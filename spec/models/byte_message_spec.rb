require "rails_helper"

RSpec.describe ByteMessage, type: :model do
  let(:user) { User.me }

  it "creates with default direction and state" do
    msg = user.byte_messages.create!(body: "hi")
    expect(msg.direction).to eq("outbound")
    expect(msg.state).to eq("pending")
  end

  it "supports the direction and state enums including :streaming" do
    streaming = user.byte_messages.create!(direction: :inbound, state: :streaming, body: "…")
    expect(streaming).to be_inbound
    expect(streaming).to be_streaming

    delivered = user.byte_messages.create!(direction: :inbound, state: :delivered, body: "yo")
    expect(delivered).to be_delivered
  end

  it "serializes to wire format with an empty attachments array by default" do
    msg = user.byte_messages.create!(body: "hey", metadata: { source: "test" })
    wire = msg.as_wire
    expect(wire).to include(id: msg.id, body: "hey", direction: "outbound", state: "pending")
    expect(wire[:metadata]).to eq("source" => "test")
    expect(wire[:attachments]).to eq([])
  end

  it "includes attachments in wire format" do
    msg = user.byte_messages.create!(body: "with file")
    msg.files.attach(
      io: StringIO.new("hello"),
      filename: "greeting.txt",
      content_type: "text/plain",
    )
    wire = msg.as_wire
    expect(wire[:attachments].size).to eq(1)
    expect(wire[:attachments].first).to include(
      filename: "greeting.txt",
      content_type: "text/plain",
      byte_size: 5,
    )
    expect(wire[:attachments].first[:url]).to match(%r{^/rails/active_storage/})
  end
end
