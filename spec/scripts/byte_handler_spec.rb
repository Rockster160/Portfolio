require "rails_helper"

# Load the Mac-side scripts directly; they don't depend on Rails so
# this is a very lightweight isolation test. Verifies routing by mode
# without spinning up the full server.
require Rails.root.join("_scripts/byte/handler")

RSpec.describe Handler do
  before do
    allow(RailsClient).to receive(:send_message).and_return({ "id" => 1 })
    allow(RailsClient).to receive(:update_message).and_return({ "id" => 1 })
    allow(Shell).to  receive(:run)
    allow(Claude).to receive(:chat)
  end

  let(:envelope) {
    {
      "message_id"      => 42,
      "user_id"         => 1,
      "conversation_id" => 7,
      "body"            => "hello",
      "metadata"        => {},
      "conversation"    => { "mode" => "claude", "metadata" => {} },
    }
  }

  it "routes plain text through Claude for claude-mode conversations" do
    expect(Claude).to receive(:chat).with(
      "hello",
      hash_including(user_id: 1, conversation_id: 7, reply_to: 42),
    )
    described_class.call(envelope)
  end

  it "routes plain text through Shell for bash-mode conversations" do
    envelope["conversation"] = { "mode" => "bash", "metadata" => {} }
    envelope["body"] = "ls -la"
    expect(Shell).to receive(:run).with(
      "ls -la",
      hash_including(user_id: 1, conversation_id: 7, reply_to: 42),
    )
    described_class.call(envelope)
  end

  it "still runs shell commands via ! in claude mode" do
    envelope["body"] = "!echo hi"
    expect(Shell).to receive(:run).with(
      "echo hi",
      hash_including(user_id: 1, conversation_id: 7),
    )
    described_class.call(envelope)
  end

  it "meta commands work regardless of mode" do
    envelope["conversation"] = { "mode" => "bash", "metadata" => {} }
    envelope["body"] = "/pwd"
    expect(RailsClient).to receive(:send_message).with(
      hash_including(conversation_id: 7, metadata: hash_including(kind: "system")),
    )
    described_class.call(envelope)
  end
end
