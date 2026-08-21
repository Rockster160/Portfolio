# == Schema Information
#
# Table name: byte_messages
#
#  id                   :bigint           not null, primary key
#  user_id              :bigint           not null
#  direction            :integer          default("outbound"), not null
#  state                :integer          default("pending"), not null
#  body                 :text
#  external_ref         :string
#  metadata             :jsonb            not null
#  delivered_at         :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#
require "rails_helper"

RSpec.describe ByteMessage, type: :model do
  let(:user) { User.me }

  # A usage row is what a turn COST. Deleting the message it was earned on used
  # to raise a foreign key violation - it stopped a backfill halfway through the
  # twelve looping briefings of 21 Aug - and deleting the spend with it would
  # have been worse: the money is a true fact about the day either way, and
  # `buddy:cost` still has to add it up.
  describe "deleting a message that cost something" do
    let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte", buddy_theme: "byte") }

    it "keeps the spend and lets the message go" do
      msg = convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hi")
      usage = BuddyUsage.create!(
        user: user, byte_conversation: convo, byte_message: msg, kind: :turn,
        model: "gpt-5.4-mini", input_tokens: 100, output_tokens: 10, cost_micros: 5_000
      )

      expect { msg.destroy! }.not_to raise_error

      expect(BuddyUsage.exists?(usage.id)).to be(true)
      expect(usage.reload.byte_message_id).to be_nil
      expect(usage.cost_micros).to eq(5_000)
    end
  end

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
      io:           StringIO.new("hello"),
      filename:     "greeting.txt",
      content_type: "text/plain",
    )
    wire = msg.as_wire
    expect(wire[:attachments].size).to eq(1)
    expect(wire[:attachments].first).to include(
      filename:     "greeting.txt",
      content_type: "text/plain",
      byte_size:    5,
    )
    expect(wire[:attachments].first[:url]).to match(%r{^/rails/active_storage/})
  end
end
