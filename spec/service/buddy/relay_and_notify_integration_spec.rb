require "rails_helper"

# Covers the two features built alongside the GPT migration, end to end through
# the new in-Rails turn path: the cross-household relay bridge and the
# "Notify others" agenda heads-up. Both reach Buddy the same way — an outbound
# seed message that BuddyDeliverWorker routes to Buddy::GPT::Turn — so the thing
# worth proving is that the seed survives into the model request and that the
# tool calls coming back still drive the relay state machine.
RSpec.describe "relay bridge and agenda notify over the GPT turn" do
  let(:rocco)   { create(:user) }
  let(:chelsea) { create(:user) }
  # first_name is derived from username on these factory users.
  let(:her)     { chelsea.username }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: rocco) }
  let!(:rocco_convo)   { rocco.byte_conversations.create!(mode: :buddy, name: "Byte") }
  let!(:chelsea_convo) { chelsea.byte_conversations.create!(mode: :buddy, name: "Moss") }

  before do
    # ChoreHousehold auto-adds its owner (rocco) as a manager member.
    ChoreHouseholdMembership.create!(chore_household: household, user: chelsea, role: :member)
    rocco.update!(chore_household_id: household.id)
    chelsea.update!(chore_household_id: household.id)

    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    # Factory users aren't in MOSS_USER_IDS, so pin the two households' themes
    # explicitly for the attribution assertions.
    allow(ByteConversation).to receive(:default_theme_for) { |u| u == chelsea ? "moss" : "byte" }
    chelsea_convo.update_columns(buddy_theme: "moss")
  end

  def run_turn(message, rounds)
    client = FakeBuddyClient.new(rounds)
    Buddy::GPT::Turn.run!(message, client: client)
    client
  end

  def latest_reply(convo)
    convo.byte_messages.where(direction: :inbound).order(:created_at).last
  end

  describe "sending a message to a partner" do
    it "fires message_partner immediately and bridges to both threads" do
      msg = rocco_convo.byte_messages.create!(
        user: rocco, direction: :outbound, state: :sent, body: "let Chelsea know I fed the dog",
      )

      run_turn(msg, [{
        text:       "On it.",
        tool_calls: [{ name: :message_partner, arguments: { "to" => her, "message" => "he fed the dog" } }],
      }])

      relay = BuddyRelay.last
      expect(relay).to have_attributes(from_user_id: rocco.id, to_user_id: chelsea.id, kind: "notify")
      expect(relay.status).to eq("delivered")

      # Chelsea sees it attributed to Rocco's Buddy; Rocco gets a copy.
      expect(chelsea_convo.byte_messages.where("metadata->>'source' = 'relay'").last.body).to eq("he fed the dog")
      expect(rocco_convo.byte_messages.where("metadata->>'source' = 'relay_copy'").last.body).to eq("he fed the dog")
    end
  end

  describe "answering a partner's open question" do
    let!(:relay) {
      BuddyRelay.create!(
        from_user: rocco, to_user: chelsea, from_conversation: rocco_convo,
        kind: :ask_open, body: "what do you want for dinner?", status: :pending
      )
    }

    before { Buddy::CompanionRelay.deliver!(relay) }

    it "puts the bridged question in Chelsea's history so a bare answer has context" do
      msg = chelsea_convo.byte_messages.create!(
        user: chelsea, direction: :outbound, state: :sent, body: "tacos",
      )

      client = run_turn(msg, [{
        text:       "Passing that along!",
        tool_calls: [{ name: :relay_answer, arguments: { "id" => relay.id, "answer" => "tacos" } }],
      }])

      history = client.calls.first.input
      expect(history.any? { |i| i[:content].to_s.include?("what do you want for dinner?") }).to be(true)
      expect(history.last).to eq({ role: :user, content: "tacos" })
    end

    it "tells Buddy an open question exists without needing a context call" do
      msg = chelsea_convo.byte_messages.create!(
        user: chelsea, direction: :outbound, state: :sent, body: "tacos",
      )

      client = run_turn(msg, [{ text: "ok" }])

      expect(client.calls.first.instructions).to include("open_questions_from_partner:** 1")
    end

    it "relays the answer back and closes out the relay" do
      msg = chelsea_convo.byte_messages.create!(
        user: chelsea, direction: :outbound, state: :sent, body: "tacos",
      )

      run_turn(msg, [{
        text:       "Passing that along!",
        tool_calls: [{ name: :relay_answer, arguments: { "id" => relay.id, "answer" => "tacos" } }],
      }])

      expect(relay.reload.answer).to eq("tacos")
      expect(relay.status).to eq("relayed")
      # The answer bridged into Rocco's original conversation.
      expect(rocco_convo.byte_messages.where("metadata->>'kind' = 'buddy_relay'").last.body).to include("tacos")
    end

    it "records cost for the answering turn like any other" do
      msg = chelsea_convo.byte_messages.create!(
        user: chelsea, direction: :outbound, state: :sent, body: "tacos",
      )

      run_turn(msg, [
        { text: "", tool_calls: [{ name: :relay_answer, arguments: { "id" => relay.id, "answer" => "tacos" } }] },
        { text: "Sent!" },
      ])

      rows = BuddyUsage.where(user: chelsea)
      # Two calls: the one that fired relay_answer, and the one that wrote the
      # reply. Both belong to the same visible message.
      expect(rows.count).to eq(2)
      expect(rows.pluck(:byte_message_id).uniq.length).to eq(1)
    end
  end

  describe "agenda notify others" do
    # Creating an item with a location would otherwise fan out to the
    # travel-chain worker (geocoding, external APIs) inline.
    before {
      allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
      allow(BuddyDeliverWorker).to receive(:perform_async)
    }

    # Sidekiq runs inline here, so deliver_prompt would otherwise fire a real
    # turn against the real client mid-setup. Hold the enqueue and drive the turn
    # explicitly with a fake client instead. That the worker DOES pick these up
    # is covered by buddy_deliver_worker_spec.

    let(:agenda) { create(:agenda, user: rocco, name: "Ours") }
    let(:item) {
      create(
        :agenda_item, agenda: agenda, kind: :event, name: "Dentist",
        start_at: Time.current.tomorrow.change(hour: 14),
        end_at:   Time.current.tomorrow.change(hour: 15)
      )
    }

    it "seeds the recipient's own Buddy, which composes the heads-up in its voice" do
      seed = Buddy::AgendaBriefing.seed(source: item, actor: rocco, recipient: chelsea, action: :created)
      # The calendar is scoped by WHOSE it is rather than by name — a calendar
      # is usually named after its owner, so naming it reads as "Rocco's Rocco
      # calendar" (see AgendaBriefing#event_phrase).
      expect(seed).to include("Dentist").and include("on their own calendar")

      outbound = Buddy::CompanionDelivery.deliver_prompt(
        user: chelsea, conversation: chelsea_convo, seed: seed,
        metadata: { kind: "buddy_trigger", hidden: true, source: "agenda_notify" }
      )

      client = run_turn(outbound, [{ text: "Heads up, Rocco put a dentist thing on the shared calendar for tomorrow afternoon." }])

      # The seed reaches the model as a user turn...
      expect(client.calls.first.input.last[:content]).to include("Dentist")
      # ...and what the person sees is Buddy's own composed prose, not the seed.
      expect(latest_reply(chelsea_convo).body).to start_with("Heads up")
      expect(latest_reply(chelsea_convo).body).not_to include("in your own voice")
    end

    it "carries a seed with no tool calls without inventing a checklist" do
      outbound = Buddy::CompanionDelivery.deliver_prompt(
        user: chelsea, conversation: chelsea_convo,
        seed: Buddy::AgendaBriefing.seed(source: item, actor: rocco, recipient: chelsea, action: :updated),
        metadata: { kind: "buddy_trigger", hidden: true }
      )

      run_turn(outbound, [{ text: "Rocco moved the dentist appointment." }])

      reply = latest_reply(chelsea_convo)
      expect(reply.state).to eq("delivered")
      expect(ByteAction.find_by(byte_message_id: reply.id)).to be_nil
    end
  end
end
