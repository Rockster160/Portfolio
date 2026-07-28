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

    # Delivery re-runs a Buddy turn (Sidekiq + Mac round-trip) and web push -
    # capture both so specs stay in-process.
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def run(tool_name, payload, user: rocco, conversation: convo)
    tool = Buddy::Tools[tool_name]
    ctx  = Buddy::ToolContext.new(user, conversation: conversation)
    confirm = tool[:confirm].call(payload, ctx)
    tool[:execute].call(payload.merge(confirm[:resolved] || {}), ctx)
  end

  # ---- sending: notify + the three ask kinds ----

  describe "message_partner (notify)" do
    it "creates a one-way relay and delivers a seed to the partner" do
      run(:message_partner, { to: her, message: "he fed the dog" })

      relay = BuddyRelay.last
      expect(relay).to have_attributes(from_user: rocco, to_user: chelsea, kind: "notify", status: "delivered")
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt)
        .with(hash_including(user: chelsea))
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
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).with(hash_including(user: rocco))
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
  end
end
