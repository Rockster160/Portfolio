require "rails_helper"

RSpec.describe Buddy::PromptDelivery do
  let(:user) { User.me }
  let!(:conversation) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }
  let(:prompt) {
    user.prompts.create!(
      question: "Who did: Puppy Down?",
      params:   { source: "ambiguous_chore", chore_name: "Puppy Down", event_id: 51_013 },
      options:  [
        { type: :select, question: "Who did it?", choices: %w[Rockster160 Eve Alchemibluum], default: "" },
        { type: :datetime, question: "When?", default: "2026-08-06T22:01" },
      ],
    )
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  describe ".post!" do
    it "posts the prompt into their Buddy thread as a form" do
      action = described_class.post!(user, prompt)

      expect(action).to be_present
      expect(action.tool_name).to eq(Buddy::FormAction::TOOL_NAME)
      expect(action.byte_conversation_id).to eq(conversation.id)
      expect(action.tool_input["tool_name"]).to eq("answer_prompt")
      expect(action.tool_input["payload"]["id"]).to eq(prompt.id)
    end

    it "carries the dropdown and the timestamp, so it's answerable where it sits" do
      action = described_class.post!(user, prompt)

      who = action.buttons.find { |f| f["key"] == "Who did it?" }
      expect(who["type"]).to eq("select")
      expect(who["choices"]).to eq(%w[Rockster160 Eve Alchemibluum])
      expect(action.buttons.find { |f| f["key"] == "When?" }["value"]).to eq("2026-08-06T22:01")
    end

    it "titles the message with the question and leaves it submittable" do
      action = described_class.post!(user, prompt)
      message = action.byte_message

      expect(message.body).to eq("Who did: Puppy Down?")
      expect(message.metadata.dig("form", "status")).to eq("pending")
      expect(message.metadata.dig("form", "submit")).to eq("Send it")
    end

    # Nothing is guessed server-side: a stored value would read as Buddy having
    # decided who did it. The dropdown still OPENS on the first name, because a
    # required select renders without a blank option — same as the prompt page.
    it "stores no answer of its own" do
      action = described_class.post!(user, prompt)
      who    = action.buttons.find { |f| f["key"] == "Who did it?" }

      expect(who["value"]).to be_blank
      expect(who["required"]).to be(true)
    end

    it "pushes it, since nothing else is going to tell them it's there" do
      allow(WebPushNotifications).to receive(:send_to_byte)

      action = described_class.post!(user, prompt)

      expect(WebPushNotifications).to have_received(:send_to_byte).with(
        title: "Who did: Puppy Down?",
        tag:   "byte-#{action.byte_message.id}",
        users: [user],
      )
    end

    it "still posts the form when the push can't go out" do
      allow(WebPushNotifications).to receive(:send_to_byte).and_raise("no subscription")

      expect(described_class.post!(user, prompt)).to be_present
    end

    # The event bus can deliver `added` twice, and a second copy of one question
    # is a second thing to dismiss.
    it "replaces an earlier form for the same prompt rather than stacking one" do
      first  = described_class.post!(user, prompt)
      second = described_class.post!(user, prompt)

      expect(first.reload).not_to be_pending
      expect(second.reload).to be_pending
      expect(ByteAction.where(tool_name: Buddy::FormAction::TOOL_NAME).pending.count).to eq(1)
    end

    it "does nothing for a prompt that's already answered" do
      prompt.update!(response: { "Who did it?" => "Eve" })

      expect(described_class.post!(user, prompt)).to be_nil
    end

    it "does nothing for someone with no Buddy thread" do
      conversation.update!(archived: true)

      expect(described_class.post!(user, prompt)).to be_nil
    end

    it "does nothing for someone who doesn't have prompts" do
      allow(Buddy::Features).to receive(:enabled?).with(user, :prompts).and_return(false)

      expect(described_class.post!(user, prompt)).to be_nil
    end
  end

  # Submitting in the thread has to be worth as much as submitting in the app:
  # same response shape, same completion trigger behind it.
  describe "submitting it from the thread" do
    it "writes the answer onto the prompt and fires the completion trigger" do
      action = described_class.post!(user, prompt)
      fired  = []
      allow(::Jil).to receive(:trigger) { |_u, kind, sent| fired << [kind, sent[:state], sent[:status]] }

      result = Buddy::FormAction.submit!(
        action, values: { "Who did it?" => "Eve", "When?" => "2026-08-06T22:01" }
      )

      expect(result[:ok]).to be(true)
      expect(prompt.reload.response).to eq("Who did it?" => "Eve", "When?" => "2026-08-06T22:01")
      # The same trigger the page fires on submit — it's what RecordLinks
      # listens for to actually complete the chore.
      expect(fired).to include([:prompt, nil, :complete])
    end

    it "refuses a name that isn't on the dropdown" do
      action = described_class.post!(user, prompt)

      result = Buddy::FormAction.submit!(action, values: { "Who did it?" => "Somebody", "When?" => "2026-08-06T22:01" })

      expect(result[:ok]).to be(false)
      expect(prompt.reload.response).to be_blank
    end

    it "refuses an empty answer rather than submitting a blank who" do
      action = described_class.post!(user, prompt)

      result = Buddy::FormAction.submit!(action, values: { "Who did it?" => "", "When?" => "2026-08-06T22:01" })

      expect(result[:ok]).to be(false)
      expect(prompt.reload.response).to be_blank
    end
  end
end
