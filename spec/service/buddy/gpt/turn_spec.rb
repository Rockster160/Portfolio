require "rails_helper"

RSpec.describe Buddy::GPT::Turn do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    convo.update_columns(buddy_theme: "byte", buddy_expression: "happy")
  end

  def user_says(text)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: text)
  end

  def run(rounds, text: "hi")
    client = FakeBuddyClient.new(rounds)
    described_class.run!(user_says(text), client: client)
    client
  end

  def reply
    convo.byte_messages.where(direction: :inbound).order(:created_at).last
  end

  describe "the reply bubble" do
    it "streams into one bubble and settles it to delivered" do
      run([{ text: "Hey there, good to hear from you." }])

      expect(reply.body).to eq("Hey there, good to hear from you.")
      expect(reply.state).to eq("delivered")
      expect(reply.delivered_at).to be_present
      expect(reply.metadata["kind"]).to eq("buddy")
    end

    it "marks the bubble failed with the error rather than leaving it streaming" do
      run([{ error: "upstream exploded" }])

      expect(reply.state).to eq("failed")
      expect(reply.body).to include("upstream exploded")
    end

    it "never leaves a bubble in streaming state after an unexpected crash" do
      client = FakeBuddyClient.new([
        { text: "whatever", tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee" } }] },
      ])
      allow(Buddy::ProposalBuilder).to receive(:create).and_raise("kaboom")

      described_class.run!(user_says("hi"), client: client)

      expect(reply.state).to eq("failed")
    end
  end

  describe "expression handling" do
    it "applies a mood the model chose even when the same reply proposes a tool" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run([{
        text:       "On it.",
        tool_calls: [
          { name: :set_mood, arguments: { "expression" => "sad" } },
          { name: :log_event, arguments: { "name" => "Coffee" } },
        ],
      }])

      expect(convo.reload.buddy_expression).to eq("sad")
    end

    it "leaves the persistent mood exactly where it was when no mood is chosen" do
      # Nothing reverts the face to a default just because a turn ended - it
      # stays put until Buddy, a check-in, or sleep deliberately moves it.
      run([{ text: "Nice." }])

      expect(convo.reload.buddy_expression).to eq("happy")
    end

    it "ignores a face the theme cannot render" do
      run([{ text: "Hm.", tool_calls: [{ name: :set_mood, arguments: { "expression" => "celebrating" } }] }])

      expect(convo.reload.buddy_expression).to eq("happy")
    end

    it "settles the expression even on a failed turn so thinking cannot stick" do
      expect(Buddy::ExpressionState).to receive(:settle!).with(convo)

      run([{ error: "nope" }])
    end
  end

  describe "malformed and unknown tool calls" do
    it "discards an unknown tool without losing the prose" do
      run([{
        text:       "Sure thing.",
        tool_calls: [{ name: :not_a_real_tool, arguments: { "x" => 1 } }],
      }])

      expect(reply.body).to eq("Sure thing.")
      expect(reply.state).to eq("delivered")
      expect(ByteAction.find_by(byte_message_id: reply.id)).to be_nil
    end

    it "falls back to an honest body when there is no prose and nothing survived" do
      run([{ text: "", tool_calls: [{ name: :not_a_real_tool, arguments: {} }] }])

      expect(reply.body).to match(/couldn't quite line that one up/i)
    end
  end

  describe "the request it builds" do
    it "sends the conversation history as roles, oldest first" do
      convo.byte_messages.create!(user: user, direction: :outbound, state: :delivered, body: "morning")
      convo.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered, body: "Morning!", metadata: { "kind" => "buddy" },
      )

      client = run([{ text: "ok" }], text: "what's up")

      expect(client.calls.first.input).to eq([
        { role: :user, content: "morning" },
        { role: :assistant, content: "Morning!" },
        { role: :user, content: "what's up" },
      ])
    end

    it "offers get_context, the silent tools, and the proposal registry" do
      client = run([{ text: "ok" }])

      names = client.calls.first.tools.pluck(:name)
      expect(names).to include(:get_context, :set_mood, :remember, :complete_chore, :log_event)
    end

    it "scopes the set_mood enum to faces this theme actually has" do
      client = run([{ text: "ok" }])

      mood = client.calls.first.tools.find { |t| t[:name] == :set_mood }
      faces = mood[:parameters][:properties][:expression][:enum]
      expect(faces).to include(:nerd, :uwu)
      expect(faces).not_to include(:sleeping, :thinking)
    end

    it "inlines the current face so a chat-only turn needs no context call" do
      client = run([{ text: "ok" }])

      expect(client.calls.first.instructions).to include("pet_expression:** happy")
    end

    it "does not leak the retired marker protocol into the prompt" do
      client = run([{ text: "ok" }])

      expect(client.calls.first.instructions).not_to include("[[propose:")
      expect(client.calls.first.instructions).not_to include("[[mood:")
    end
  end

  describe "stray marker defense" do
    it "strips a marker the model emitted anyway rather than showing brackets" do
      run([{ text: "Done. [[mood: happy]]" }])

      expect(reply.body).to eq("Done.")
    end
  end

  describe "cost accounting" do
    it "records one usage row per API call, attached to the reply" do
      run([{ text: "Nice." }])

      rows = BuddyUsage.where(byte_message_id: reply.id)
      expect(rows.count).to eq(1)
      expect(rows.first).to have_attributes(kind: "turn", model: "gpt-5.4-mini", user_id: user.id)
      expect(rows.first.cost_micros).to be > 0
    end

    it "records a row per round when the turn round-trips through get_context" do
      run([
        { text: "One sec.", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "Nothing left." },
      ])

      expect(BuddyUsage.where(byte_message_id: reply.id).count).to eq(2)
    end

    it "stamps the per-message total onto the reply so the client needs no join" do
      run([{ text: "Nice." }])

      rollup = reply.metadata["usage"]
      expect(rollup["calls"]).to eq(1)
      expect(rollup["input_tokens"]).to eq(1_000)
      expect(rollup["cached_input_tokens"]).to eq(800)
      expect(rollup["output_tokens"]).to eq(100)
      expect(rollup["cost_micros"]).to eq(BuddyUsage.where(byte_message_id: reply.id).sum(:cost_micros))
    end

    it "still records and stamps cost when the turn fails" do
      # A failed or truncated response consumed tokens and bills for them.
      run([{ error: "context length exceeded" }])

      expect(reply.state).to eq("failed")
      expect(BuddyUsage.where(byte_message_id: reply.id).count).to eq(1)
      expect(reply.metadata["usage"]["cost_micros"]).to be > 0
    end

    it "records nothing when the request was rejected outright and billed nothing" do
      run([{ error: "invalid schema", usage: nil }])

      expect(BuddyUsage.where(byte_message_id: reply.id)).to be_empty
    end

    it "does not fail a turn just because usage could not be recorded" do
      allow(BuddyUsage).to receive(:record!).and_raise("accounting is down")

      run([{ text: "Still fine." }])

      expect(reply.body).to eq("Still fine.")
      expect(reply.state).to eq("delivered")
    end
  end

  describe "round-trip limit" do
    it "stops re-reading context after the cap instead of looping" do
      rounds = Array.new(6) {
        { text: "checking", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] }
      }
      client = run(rounds)

      expect(client.calls.length).to eq(described_class::MAX_ROUND_TRIPS)
      expect(reply.state).to eq("delivered")
    end
  end
end
