require "rails_helper"

RSpec.describe ByteJarvisWorker do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(name: "jarv", mode: :jarvis) }
  let(:message) {
    convo.byte_messages.create!(
      user:      user,
      direction: :outbound,
      state:     :pending,
      body:      "turn on the kitchen lights",
    )
  }

  it "posts a Jarvis response back as an inbound message on the same conversation" do
    allow(::Jarvis).to receive(:command).with(user, message.body).and_return("done — kitchen on")

    expect {
      described_class.new.perform(message.id)
    }.to change { convo.byte_messages.inbound.count }.by(1)

    reply = convo.byte_messages.inbound.last
    expect(reply.body).to eq("done — kitchen on")
    expect(reply.state).to eq("delivered")
    expect(reply.metadata["kind"]).to eq("jarvis")
    expect(reply.metadata["in_reply_to"]).to eq(message.id)
  end

  it "flips a pending outbound to sent so the composer's spinner clears" do
    allow(::Jarvis).to receive(:command).and_return("k")
    described_class.new.perform(message.id)
    expect(message.reload.state).to eq("sent")
  end

  it "handles Jarvis raising by surfacing a failed system message" do
    allow(::Jarvis).to receive(:command).and_raise(StandardError, "boom")

    expect {
      described_class.new.perform(message.id)
    }.to change { convo.byte_messages.inbound.count }.by(1)

    err = convo.byte_messages.inbound.last
    expect(err.state).to eq("failed")
    expect(err.body).to include("Jarvis error")
    expect(err.metadata["error"]).to eq(true)
  end

  it "is a no-op for a missing message id" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end

  # A Jil task that ran leaves the same receipt a Buddy tool call does, so "did
  # that actually do anything?" is answered by the thread rather than by trusting
  # the sentence underneath it.
  describe "receipts for the Jil tasks that ran" do
    let(:task) {
      Task.create!(user: user, name: "Garage Door", listener: "tell:garage", code: "", enabled: true)
    }

    it "files a chip per task, before the reply" do
      allow(::Jarvis).to receive(:command) { |_u, _w, &blk|
        blk&.call([task])
        "Opening the garage."
      }

      described_class.new.perform(message.id)

      chip = convo.byte_messages.where("metadata->>'kind' = ?", "buddy_activity").last
      expect(chip.body).to eq("Called **Garage Door**")
      expect(chip.metadata["tool_name"]).to eq("jarvis_task")
      expect(chip.metadata["payload"]["task_name"]).to eq("Garage Door")
      expect(chip.id).to be < convo.byte_messages.where("metadata->>'kind' = ?", "jarvis").last.id
    end

    # Half the enabled `tell:` tasks say nothing back — they just do the thing.
    it "says nothing under the receipt when the task had nothing to say" do
      allow(::Jarvis).to receive(:command) { |_u, _w, &blk|
        blk&.call([task])
        nil
      }

      described_class.new.perform(message.id)

      expect(convo.byte_messages.where("metadata->>'kind' = ?", "jarvis")).to be_empty
      expect(convo.byte_messages.where("metadata->>'kind' = ?", "buddy_activity").count).to eq(1)
    end

    # Backstop only. In the real chain no task matching means Jarvis::Talk
    # answers unconditionally ("I don't know how to X, sir."), so this shape
    # shouldn't occur — but a message that vanished is worse than an odd one.
    it "still says something if Jarvis ever answers nothing with nothing run" do
      allow(::Jarvis).to receive(:command) { |_u, _w, &blk|
        blk&.call([])
        nil
      }

      described_class.new.perform(message.id)

      expect(convo.byte_messages.inbound.last.body).to eq("(no response)")
    end

    it "files nothing when the words only reached Jarvis's own fallbacks" do
      allow(::Jarvis).to receive(:command) { |_u, _w, &blk|
        blk&.call([])
        "Sure."
      }

      chips = -> { convo.byte_messages.where("metadata->>'kind' = ?", "buddy_activity").count }
      expect { described_class.new.perform(message.id) }.not_to change(chips, :call)
    end
  end

  # The dot is the routing marker, not part of what they said.
  it "strips the prefix before Jarvis sees it" do
    aside = convo.byte_messages.create!(
      user: user, direction: :outbound, state: :sent, body: ".turn on the kitchen lights",
    )
    expect(::Jarvis).to receive(:command).with(user, "turn on the kitchen lights").and_return("k")

    described_class.new.perform(aside.id)
  end
end
