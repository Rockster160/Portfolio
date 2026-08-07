require "rails_helper"

# Cross-user companion messaging: one person's Buddy relaying a message or a
# question into their household partner's Buddy, and carrying answers back.
RSpec.describe "Buddy companion relay" do
  let(:rocco)   { create(:user) }
  let(:chelsea) { create(:user) }
  let(:her)     { chelsea.username } # what Rocco calls her (first_name == username here)
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: rocco) }
  let!(:convo) { ByteConversation.create!(user: rocco, mode: :buddy, name: "Buddy") }

  before do
    # ChoreHousehold auto-adds its owner (rocco) as a manager member.
    ChoreHouseholdMembership.create!(chore_household: household, user: chelsea, role: :member)
    rocco.update!(chore_household_id: household.id)
    chelsea.update!(chore_household_id: household.id)

    # Relays now post direct bridged messages (broadcast + push), no recompose.
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    # Random test users aren't in MOSS_USER_IDS, so differentiate the two
    # households' themes explicitly for the attribution assertions.
    allow(ByteConversation).to receive(:default_theme_for) { |u| u == chelsea ? "moss" : "byte" }
  end

  def source(conversation, src)
    conversation.byte_messages.where("metadata->>'source' = ?", src).order(:created_at).last
  end

  def run(tool_name, payload, user: rocco, conversation: convo)
    tool = Buddy::Tools[tool_name]
    ctx  = Buddy::ToolContext.new(user, conversation: conversation)
    confirm = tool[:confirm].call(payload, ctx)
    tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx)
  end

  # ---- sending: notify + the three ask kinds ----

  describe "message_partner (notify)" do
    it "bridges the message to the partner and drops an attributed copy for the sender" do
      run(:message_partner, { to: her, message: "he fed the dog" })

      relay = BuddyRelay.last
      expect(relay).to have_attributes(from_user: rocco, to_user: chelsea, kind: "notify", status: "delivered")

      # Chelsea sees it attributed to Rocco's Buddy (Byte).
      to_msg = source(relay.to_conversation, "relay")
      expect(to_msg.body).to eq("he fed the dog")
      expect(to_msg.metadata.dig("relay_peer", "name")).to eq("Byte")

      # Rocco's own thread gets an outgoing copy carrying both identities, so
      # it renders as "Byte → Moss" instead of looking like Moss said it.
      copy = source(convo, "relay_copy")
      expect(copy.body).to eq("he fed the dog")
      expect(copy.metadata.dig("relay_from", "name")).to eq("Byte")
      expect(copy.metadata.dig("relay_peer", "name")).to eq("Moss")
    end

    it "leaves the recipient's copy without a sender-side arrow" do
      run(:message_partner, { to: her, message: "he fed the dog" })

      expect(source(BuddyRelay.last.to_conversation, "relay").metadata).not_to have_key("relay_from")
    end

    it "refuses a name that isn't in the household" do
      tool = Buddy::Tools[:message_partner]
      ctx  = Buddy::ToolContext.new(rocco, conversation: convo)
      expect { tool[:confirm].call({ to: "Nobody", message: "hi" }, ctx) }.to raise_error(/not sure who/)
    end
  end

  describe "ask_partner (open)" do
    it "creates an ask_open relay awaiting an answer" do
      run(:ask_partner, { to: her, question: "what she wants for dinner" })

      relay = BuddyRelay.last
      expect(relay).to have_attributes(kind: "ask_open", status: "delivered")
      expect(BuddyRelay.open_questions_for(chelsea)).to include(relay)
    end
  end

  describe "ask_partner_choice / ask_partner_multi" do
    it "attaches a checkbox action with one row per option (choice = instant)" do
      run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })

      relay = BuddyRelay.last
      expect(relay.kind).to eq("ask_choice")
      action = relay.to_byte_action
      expect(action.tool_name).to eq("buddy_relay_answer")
      expect(action.buttons.pluck("label")).to eq(%w[dishes mop])
      expect(relay.to_conversation.byte_messages.last.metadata["select_mode"]).to eq("instant")
    end

    it "marks multi questions as confirm-mode (Send button)" do
      run(:ask_partner_multi, { to: her, question: "which resonate?", options: "words, time, touch" })

      relay = BuddyRelay.last
      expect(relay.kind).to eq("ask_multi")
      expect(relay.to_conversation.byte_messages.last.metadata["select_mode"]).to eq("confirm")
    end

    it "rejects fewer than two options" do
      tool = Buddy::Tools[:ask_partner_choice]
      ctx  = Buddy::ToolContext.new(rocco, conversation: convo)
      expect { tool[:confirm].call({ to: her, question: "?", options: "only one" }, ctx) }
        .to raise_error(/at least two/)
    end

    # Prod 2212: the question landed in Rocco's thread as plain text with no way
    # to answer it, and the buttons only turned up later. The message went out
    # the instant it was created, and the action was attached after.
    it "sends the question with its answers already on it" do
      sent = []
      allow(MonitorChannel).to receive(:broadcast_to) { |user, payload|
        sent << payload.dig(:data, :message) if user == chelsea
      }

      run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })

      question = sent.find { |m| m[:metadata]["source"] == "relay" }
      expect(question[:metadata]["buttons"].pluck("label")).to eq(%w[dishes mop])
      expect(question[:metadata]["select_mode"]).to eq("instant")
    end

    it "only sends it once, so the options don't arrive as a second draw" do
      sent = []
      allow(MonitorChannel).to receive(:broadcast_to) { |user, payload|
        sent << payload.dig(:data, :message) if user == chelsea
      }

      run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })

      expect(sent.count { |m| m[:metadata]["source"] == "relay" }).to eq(1)
    end

    it "leaves a plain message alone - there's nothing to attach" do
      run(:message_partner, { to: her, message: "he fed the dog" })

      expect(BuddyRelay.last.to_conversation.byte_messages.last.metadata).not_to have_key("buttons")
    end
  end

  # ---- answering ----

  describe "answering a checkbox question" do
    it "records a single choice and relays it back to the asker" do
      run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })
      relay  = BuddyRelay.last
      action = relay.to_byte_action

      Buddy::CompanionRelay.answer_from_action(action, [2]) # "mop"

      expect(relay.reload).to have_attributes(answer: "mop", status: "relayed")
      expect(action.reload.buttons.find { |b| b["id"] == 2 }["status"]).to eq("executed")
      expect(action.buttons.find { |b| b["id"] == 1 }["status"]).to eq("cancelled")

      # The answer is bridged back to Rocco, attributed to Chelsea's Buddy (Moss).
      answer_msg = source(convo, "relay")
      expect(answer_msg.body).to eq("mop")
      expect(answer_msg.metadata.dig("relay_peer", "name")).to eq("Moss")
    end

    it "records a multi answer as the full set of picked labels" do
      run(:ask_partner_multi, { to: her, question: "which resonate?", options: "words, time, touch" })
      relay  = BuddyRelay.last
      action = relay.to_byte_action

      Buddy::CompanionRelay.answer_from_action(action, [1, 3]) # words + touch

      expect(relay.reload.answer).to eq(%w[words touch])
      expect(relay.status).to eq("relayed")
    end

    it "is idempotent - a second answer is ignored" do
      run(:ask_partner_choice, { to: her, question: "dishes or mop?", options: "dishes, mop" })
      relay  = BuddyRelay.last
      action = relay.to_byte_action

      Buddy::CompanionRelay.answer_from_action(action, [1])
      Buddy::CompanionRelay.answer_from_action(action, [2])

      expect(relay.reload.answer).to eq("dishes")
    end
  end

  describe "relay_answer tool (open-ended, from the recipient's Buddy)" do
    it "records the free-text answer and relays it back" do
      run(:ask_partner, { to: her, question: "dinner?" })
      relay = BuddyRelay.last

      tool = Buddy::Tools[:relay_answer]
      ctx  = Buddy::ToolContext.new(chelsea, conversation: convo)
      confirm = tool[:confirm].call({ id: relay.id, answer: "tacos" }, ctx)
      tool[:execute].call({ id: relay.id, answer: "tacos" }.merge(confirm[:resolved]), ctx)

      expect(relay.reload).to have_attributes(answer: "tacos", status: "relayed")
    end

    it "does not answer someone else's relay" do
      run(:ask_partner, { to: her, question: "dinner?" })
      relay = BuddyRelay.last

      tool = Buddy::Tools[:relay_answer]
      # rocco is the ASKER, not the recipient - no open question addressed to him.
      ctx  = Buddy::ToolContext.new(rocco, conversation: convo)
      expect { tool[:confirm].call({ id: relay.id, answer: "x" }, ctx) }.to raise_error(/no open question/)
    end
  end

  # ---- context surfaces open questions to the recipient ----

  describe "context pending_relays" do
    it "lists open questions addressed to the user" do
      run(:ask_partner, { to: her, question: "dinner?" })
      relay = BuddyRelay.last

      relays = Buddy::Context.send(:pending_relays, chelsea)
      expect(relays).to include(hash_including(id: relay.id, from: rocco.first_name, question: "dinner?"))
    end

    it "drops a question once it's answered" do
      run(:ask_partner, { to: her, question: "dinner?" })
      Buddy::CompanionRelay.record_answer!(BuddyRelay.last, "tacos")

      expect(Buddy::Context.send(:pending_relays, chelsea)).to be_empty
    end

    # Prod Aug 7: Chelsea asked "Are we leaving at 5:30?" on Aug 3. Nobody
    # answered and nothing closed it, so it was still listed as an open
    # question through four days of unrelated conversation — and when a stray
    # "Tick" arrived from the CLI, Buddy did exactly what an open question tells
    # it to do and sent "Tick" back to her as Rocco's answer.
    #
    # The measure is messages, not minutes: an answer is the next thing they
    # say, and anything else means the question went by.
    describe "a question that went unanswered" do
      let!(:her_convo) {
        chelsea.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: Time.current)
      }
      let!(:question) {
        run(:ask_partner, { to: her, question: "Are we leaving at 5:30?" })
        BuddyRelay.last
      }

      def she_says(body)
        her_convo.byte_messages.create!(user: chelsea, direction: :outbound, state: :sent, body: body)
      end

      def open_now
        Buddy::Context.send(:pending_relays, chelsea, her_convo)
      end

      it "is open on the very next thing she says" do
        she_says("Tick")

        expect(open_now).to include(hash_including(id: question.id))
      end

      it "is gone the moment she has said anything else first" do
        she_says("what's the weather")
        she_says("Tick")

        expect(open_now).to be_empty
      end

      # The boundary, stated exactly: the first message after the question is
      # the chance to answer it, and the second one has already passed it over.
      # One is enough — it doesn't take a hundred, or three days.
      it "closes on the second message, not the first" do
        she_says("Tick")
        expect(open_now).not_to be_empty

        she_says("Tick")
        expect(open_now).to be_empty
      end

      it "can no longer be answered, so nothing stray gets passed along" do
        she_says("what's the weather")
        she_says("Tick")
        tool = Buddy::Tools[:relay_answer]
        ctx  = Buddy::ToolContext.new(chelsea, conversation: her_convo)

        expect { tool[:confirm].call({ id: question.id, answer: "Tick" }, ctx) }
          .to raise_error(/no open question/)
        expect(question.reload.answer).to be_blank
      end

      # Days of silence say nothing either way — what matters is whether she
      # spoke without answering.
      it "survives a long gap as long as she hasn't spoken since" do
        question.update!(created_at: 2.weeks.ago)
        she_says("Tick")

        expect(open_now).to include(hash_including(id: question.id))
      end

      it "doesn't count Buddy's own hidden seeds as her passing it over" do
        her_convo.byte_messages.create!(
          user: chelsea, direction: :outbound, state: :sent, body: "[tapped Today]",
          metadata: { "hidden" => true, "kind" => "buddy_trigger" },
        )
        she_says("Tick")

        expect(open_now).to include(hash_including(id: question.id))
      end
    end
  end
end
