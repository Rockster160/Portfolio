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

  # Prod, 26 Aug 16:49: ".close blinds" reached a Home Assistant that was down,
  # the POST sat on RestClient's 60-second read timeout, and the thread showed
  # nothing at all for a full minute - no receipt, no pending state, no face.
  # The reply when it finally came was correct, but for that minute there was no
  # way to tell a stalled command from one that never sent. Buddy's own turns
  # have always shown a thinking face; a Jarvis aside is the one route into a
  # Buddy thread that didn't, and it's the route with the longest wait on it.
  describe "while the command is still running" do
    it "shows that it's in hand before Jarvis is called" do
      order = []
      allow(Buddy::ExpressionState).to receive(:thinking!) { order << :thinking }
      allow(::Jarvis).to receive(:command) { order.push(:command) && "k" }

      described_class.new.perform(message.id)

      expect(order).to eq(%i[thinking command])
    end

    # The face says the companion is busy; the bubble says which command it's
    # busy with, sitting in the thread under the words they typed.
    it "opens the reply bubble before Jarvis is called" do
      seen = nil
      allow(::Jarvis).to receive(:command) {
        seen = convo.byte_messages.inbound.last
        "k"
      }

      described_class.new.perform(message.id)

      expect(seen).to have_attributes(state: "streaming", body: "")
      expect(seen.metadata["kind"]).to eq("jarvis")
    end

    it "fills that same row in rather than posting a second one" do
      allow(::Jarvis).to receive(:command).and_return("done — kitchen on")

      expect { described_class.new.perform(message.id) }
        .to change { convo.byte_messages.inbound.count }.by(1)

      expect(convo.byte_messages.inbound.last).to have_attributes(
        state: "delivered", body: "done — kitchen on",
      )
    end

    it "takes the bubble away when the chip is the whole answer" do
      task = Task.create!(user: user, name: "Darkness", listener: "tell:dark", code: "", enabled: true)
      allow(::Jarvis).to receive(:command) { |_u, _w, &blk|
        blk&.call([task])
        ""
      }

      described_class.new.perform(message.id)

      expect(convo.byte_messages.inbound.where(state: :streaming)).to be_empty
      expect(convo.byte_messages.inbound.pluck(:body)).to eq(["Called **Darkness**"])
    end

    # A bubble left spinning next to an error message reads as two things
    # having gone wrong.
    it "takes the bubble away when Jarvis raises" do
      allow(::Jarvis).to receive(:command).and_raise(StandardError, "boom")

      described_class.new.perform(message.id)

      expect(convo.byte_messages.inbound.where(state: :streaming)).to be_empty
      expect(convo.byte_messages.inbound.last.body).to include("Jarvis error")
    end

    it "settles the face again once the reply is out" do
      allow(::Jarvis).to receive(:command).and_return("k")
      allow(Buddy::ExpressionState).to receive(:settle!)

      described_class.new.perform(message.id)

      expect(Buddy::ExpressionState).to have_received(:settle!).with(convo)
    end

    # Otherwise a command that blows up leaves the pet thinking forever.
    it "settles it even when Jarvis raises" do
      allow(::Jarvis).to receive(:command).and_raise(StandardError, "boom")
      allow(Buddy::ExpressionState).to receive(:settle!)

      described_class.new.perform(message.id)

      expect(Buddy::ExpressionState).to have_received(:settle!).with(convo)
    end
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
      # By created_at, not by id. The reply row is opened BEFORE the command
      # runs so the thread can show a thinking bubble, which puts its id below
      # every chip; its created_at moves to now as it settles, and created_at
      # is what the thread sorts on.
      expect(chip.created_at).to be < convo.byte_messages.where("metadata->>'kind' = ?", "jarvis").last.created_at
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
