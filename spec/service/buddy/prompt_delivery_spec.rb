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

  def message_actions(action)
    action.byte_message.reload.metadata.dig("form", "actions")
  end

  describe ".post!" do
    # Nothing is guessed server-side: a stored value would read as Buddy having
    # decided who did it. A prompt that arrives unasked-for needs a way out that
    # isn't answering it.
    it "posts the prompt into their Buddy thread as a pushed, answerable form", :aggregate_failures do
      allow(WebPushNotifications).to receive(:send_to_byte)

      action = described_class.post!(user, prompt)

      expect(action.tool_name).to eq(Buddy::FormAction::TOOL_NAME)
      expect(action.byte_conversation_id).to eq(conversation.id)
      expect(action.tool_input["tool_name"]).to eq("answer_prompt")
      expect(action.tool_input["payload"]["id"]).to eq(prompt.id)

      who = action.buttons.find { |f| f["key"] == "Who did it?" }
      expect(who).to include("type" => "select", "choices" => %w[Rockster160 Eve Alchemibluum], "required" => true)
      expect(who["value"]).to be_blank
      expect(action.buttons.find { |f| f["key"] == "When?" }["value"]).to eq("2026-08-06T22:01")

      message = action.byte_message
      expect(message.body).to eq("Who did: Puppy Down?")
      expect(message.metadata.dig("form", "status")).to eq("pending")
      expect(message_actions(action).pluck("key")).to eq(%w[skip submit])

      expect(WebPushNotifications).to have_received(:send_to_byte).with(
        title: "Who did: Puppy Down?",
        tag:   "byte-#{message.id}",
        users: [user],
      )
    end

    it "still posts the form when the push can't go out" do
      allow(WebPushNotifications).to receive(:send_to_byte).and_raise("no subscription")

      expect(described_class.post!(user, prompt)).to be_present
    end

    # The event bus can deliver `added` twice, and a second copy of one question
    # is a second thing to dismiss.
    it "replaces an earlier form for the same prompt rather than stacking one", :aggregate_failures do
      first  = described_class.post!(user, prompt)
      second = described_class.post!(user, prompt)

      expect(first.reload).not_to be_pending
      expect(second.reload).to be_pending
      expect(ByteAction.where(tool_name: Buddy::FormAction::TOOL_NAME).pending.count).to eq(1)
    end

    it "does nothing for an answered prompt, someone with no thread, or someone without prompts", :aggregate_failures do
      allow(Buddy::Features).to receive(:enabled?).and_call_original
      allow(Buddy::Features).to receive(:enabled?).with(user, :prompts).and_return(false)
      expect(described_class.post!(user, prompt)).to be_nil

      allow(Buddy::Features).to receive(:enabled?).with(user, :prompts).and_return(true)
      conversation.update!(archived: true)
      expect(described_class.post!(user, prompt)).to be_nil

      conversation.update!(archived: false)
      prompt.update!(response: { "Who did it?" => "Eve" })
      expect(described_class.post!(user, prompt)).to be_nil
    end
  end

  # Some prompts fill their choices in as they're opened, on `prompt:load`.
  # The form in the thread runs the same step and rebuilds from what it left.
  describe "refreshing the form" do
    let(:action) { described_class.post!(user, prompt) }

    before do
      allow(Jil).to receive(:trigger).and_call_original
      allow(Jil).to receive(:trigger).with(user, :prompt, anything, auth: :trigger) { |_, _, data|
        next unless data[:state] == :load

        prompt.update!(
          question: "Who did: Puppy Up?",
          options:  [{ type: :select, question: "Who did it?", choices: %w[Rockster160 Eve], default: "" }],
        )
      }
    end

    it "asks to be refreshed, then runs the prompt's load step and repaints the fields and title", :aggregate_failures do
      expect(action.byte_message.metadata.dig("form", "refresh")).to be(true)

      message = Buddy::FormAction.refresh!(action)

      expect(message.body).to eq("Who did: Puppy Up?")
      expect(message.metadata.dig("form", "fields").pluck("key")).to eq(["Who did it?"])
      expect(action.reload.buttons.first["choices"]).to eq(%w[Rockster160 Eve])
      expect(message.metadata.dig("form", "status")).to eq("pending")
    end

    it "leaves a form that's already been answered alone" do
      action.update!(state: :decided)

      expect(Buddy::FormAction.refresh!(action)).to be_nil
    end

    it "runs the load step once, not again while reading the fields back" do
      action
      loads = 0
      allow(Jil).to receive(:trigger).with(user, :prompt, anything, any_args) { |_, _, data| loads += 1 if data[:state] == :load }

      Buddy::FormAction.refresh!(action)

      expect(loads).to eq(1)
    end
  end

  # A task changing the prompt after the form went out - a guess that took a
  # while - reaches the form on screen, and doesn't run the load step to do it.
  describe "a prompt changing while its form is out" do
    let!(:action) { described_class.post!(user, prompt) }

    it "repaints the form from the prompt as it is now", :aggregate_failures do
      allow(Jil).to receive(:trigger).and_call_original
      prompt.update!(options: prompt.options + [{ type: :text, question: "Notes", default: "Left early" }])

      fields = action.byte_message.reload.metadata.dig("form", "fields")
      expect(fields.find { |f| f["key"] == "Notes" }).to include("value" => "Left early")
      expect(action.reload.buttons.pluck("key")).to include("Notes")
      expect(Jil).not_to have_received(:trigger).with(user, :prompt, anything, any_args)
      expect(MonitorChannel).to have_received(:broadcast_to).with(
        user,
        hash_including(data: hash_including(kind: :message)),
      ).at_least(:once)
    end

    it "leaves it alone once the prompt is answered" do
      prompt.update!(response: { "Who did it?" => "Eve" }, options: [])

      expect(action.byte_message.reload.metadata.dig("form", "fields").pluck("key")).to include("Who did it?")
    end
  end

  # Submitting in the thread has to be worth as much as submitting in the app:
  # same response shape, same completion trigger behind it.
  describe "submitting it from the thread" do
    it "writes the answer onto the prompt and fires the completion trigger", :aggregate_failures do
      action = described_class.post!(user, prompt)
      fired  = []
      allow(::Jil).to receive(:trigger) { |_u, kind, sent| fired << [kind, sent[:state], sent[:status]] }

      result = Buddy::FormAction.submit!(
        action, values: { "Who did it?" => "Eve", "When?" => "2026-08-06T22:01" }
      )

      expect(result[:ok]).to be(true)
      expect(prompt.reload.response).to eq("Who did it?" => "Eve", "When?" => "2026-08-06T22:01")
      # The trigger RecordLinks listens for to actually complete the chore.
      expect(fired).to include([:prompt, nil, :complete])
    end

    it "refuses a name that isn't on the dropdown, or an empty one", :aggregate_failures do
      action = described_class.post!(user, prompt)

      ["Somebody", ""].each do |who|
        result = Buddy::FormAction.submit!(action, values: { "Who did it?" => who, "When?" => "2026-08-06T22:01" })
        expect(result[:ok]).to be(false), who.inspect
      end
      expect(prompt.reload.response).to be_blank
    end
  end

  # The same question exists in two places at once, so answering it in either
  # has to close it in both.
  describe "settling a form answered elsewhere" do
    def form_of(action)
      action.byte_message.reload.metadata["form"]
    end

    it "shows what was answered, keeps the question in the thread, and stops being answerable", :aggregate_failures do
      action  = described_class.post!(user, prompt)
      message = action.byte_message

      # What PromptsController#update does: write the response, fire the trigger.
      prompt.update!(response: { "Who did it?" => "Eve", "When?" => "2026-08-06T22:01" })
      ::Jil.trigger(user, :prompt, prompt.with_jil_attrs(status: :complete))

      form = form_of(action)
      expect(form["status"]).to eq("submitted")
      expect(form["fields"].find { |f| f["key"] == "Who did it?" }["value"]).to eq("Eve")
      expect(form["fields"].pluck("key")).to eq(["Who did it?", "When?"])
      expect(action.reload).not_to be_pending
      expect(message.reload.body).to eq("Who did: Puppy Down?")
    end

    # Every skip door destroys the prompt and THEN fires the trigger, so the
    # destroy callback gets there first.
    it "closes it with nothing filled in when it's dismissed there", :aggregate_failures do
      action = described_class.post!(user, prompt)
      fields = action.buttons

      prompt.destroy
      described_class.dispatch(user, :prompt, prompt.with_jil_attrs(status: :skip))

      form = form_of(action)
      expect(form["status"]).to eq("submitted")
      expect(form["receipt"]).to eq(described_class::DISCARDED)
      expect(form["fields"]).to eq(fields)
    end

    it "leaves it alone while the prompt is only being opened", :aggregate_failures do
      action = described_class.post!(user, prompt)

      described_class.dispatch(user, :prompt, prompt.with_jil_attrs(state: :load))

      expect(action.reload).to be_pending
      expect(form_of(action)["status"]).to eq("pending")
    end

    it "settles only the form for THAT prompt", :aggregate_failures do
      other = user.prompts.create!(question: "How was it?", options: [
        { type: :text, question: "Notes", default: "" },
      ])
      action = described_class.post!(user, prompt)
      spared = described_class.post!(user, other)

      prompt.update!(response: { "Who did it?" => "Eve", "When?" => "2026-08-06T22:01" })
      described_class.dispatch(user, :prompt, prompt.with_jil_attrs(status: :complete))

      expect(action.reload).not_to be_pending
      expect(spared.reload).to be_pending
    end

    # answer_prompt fires `prompt:complete` from inside the submit, so the
    # settler is handed the very form being submitted. If it took it, both would
    # claim the deferred queue and run whatever was behind it twice.
    it "stands down when the thread is the one submitting it", :aggregate_failures do
      action = described_class.post!(user, prompt)
      seen = nil
      allow(Buddy::FormAction).to(receive(:settle!).and_wrap_original { |orig, *args, **kwargs|
        seen = orig.call(*args, **kwargs)
      })

      Buddy::FormAction.submit!(action, values: { "Who did it?" => "Eve", "When?" => "2026-08-06T22:01" })

      expect(seen).to be(false)
      expect(action.reload.decision["source"]).to eq("user")
    end
  end

  # A destroy from a script or console fires nothing on the trigger bus, and the
  # form must not be left pointing at a prompt that no longer exists.
  describe "a prompt that is deleted rather than answered" do
    it "settles its own open form with no trigger, keeping the question to read", :aggregate_failures do
      other = user.prompts.create!(question: "How was it?", options: [
        { type: :text, question: "Notes", default: "" },
      ])
      action  = described_class.post!(user, prompt)
      spared  = described_class.post!(user, other)
      message = action.byte_message
      expect(::Jil).not_to receive(:trigger)

      prompt.destroy!

      expect(action.reload).not_to be_pending
      form = message.reload.metadata["form"]
      expect(form["status"]).to eq("submitted")
      expect(form["receipt"]).to eq(described_class::DISCARDED)
      expect(message.body).to eq("Who did: Puppy Down?")
      expect(spared.reload).to be_pending
    end

    # A prompt nobody posted is the common case, and a callback that raised on
    # one would take the destroy down with it.
    it "is a no-op when there was never a form" do
      loose = user.prompts.create!(question: "Anything?", options: [])

      expect { loose.destroy! }.not_to raise_error
    end
  end
end
