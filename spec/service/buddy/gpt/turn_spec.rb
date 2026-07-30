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

  # Both regressions came off one real prod message (1041): "Just hung the shelves
  # for Chelsea" produced "You got it, checking that off." printed twice, with no
  # checkbox, and no chore completion recorded anywhere.
  describe "when the model says the same line twice" do
    it "does not print it twice when it lands in both output text and the reply field" do
      run([{
        text:       "You got it, checking that off.",
        tool_calls: [{ name: :log_event, arguments: { "name" => "Shelves", "reply" => "You got it, checking that off." } }],
      }])

      expect(reply.body).to eq("You got it, checking that off.")
    end

    it "ignores punctuation and case drift between the two copies" do
      run([{
        text:       "You got it, checking that off.",
        tool_calls: [{ name: :log_event, arguments: { "name" => "x", "reply" => "You got it — checking that off!" } }],
      }])

      expect(reply.body.scan(/checking that off/i).length).to eq(1)
    end

    it "still keeps two lines that actually say different things" do
      run([
        { text: "One sec.", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "Nothing left on your list." },
      ])

      expect(reply.body).to eq("One sec.\n\nNothing left on your list.")
    end
  end

  describe "when every proposal is discarded" do
    # ProposalBuilder drops a call whose target can't be resolved — an archived
    # chore, a name that matches nothing. That is silent, and the model has
    # already written "checking that off" by then.
    before { allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: false) }

    it "does not leave a confident claim standing over a reply that did nothing" do
      run([{
        tool_calls: [{ name: :complete_chore, arguments: { "chore" => "hang the shelves", "reply" => "You got it, checking that off." } }],
      }])

      expect(reply.body).not_to match(/checking that off/i)
      expect(reply.body).to match(/couldn't quite line that one up/i)
    end

    it "leaves the reply alone when something actually ran" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run([{
        tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes", "reply" => "Nice, that's done." } }],
      }])

      expect(reply.body).to eq("Nice, that's done.")
    end

    it "leaves a pure-conversation reply alone, since nothing was claimed" do
      run([{ text: "Not much on my end, how's your night?" }])

      expect(reply.body).to eq("Not much on my end, how's your night?")
    end
  end

  # Hard check, not prompt guidance: this has broken twice in prod. Claiming an
  # action happened when nothing ran is the worst failure mode for something whose
  # job is keeping a record, because nothing signals that it went wrong.
  describe "retracting a completion claim nothing backs up" do
    it "retracts a timer claim made with no tool call at all" do
      # Real prod bug: "5m" produced this with no set_timer call.
      run([{ text: "Kk! Timer's set for 5 minutes." }])

      expect(reply.body).to match(/couldn't quite line that one up/i)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "retracts a checking-that-off claim when the tool resolved to nothing" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: false)

      run([{ text: "You got it, checking that off." }])

      expect(reply.body).not_to match(/checking that off/i)
    end

    it "leaves the claim alone when a level-1 tool actually fired" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run([{ tool_calls: [{ name: :schedule_reminder, arguments: { "text" => "call mom", "reply" => "Reminder's set for 6." } }] }])

      expect(reply.body).to eq("Reminder's set for 6.")
    end

    it "leaves the claim alone when a level-2 row came back executed" do
      action = instance_double(ByteAction, buttons: [{ "status" => "executed" }])
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: action, auto_ran: false)

      run([{ tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes", "reply" => "Nice, that's logged." } }] }])

      expect(reply.body).to eq("Nice, that's logged.")
    end

    it "leaves it alone when a pending row is visible, since the person can see it" do
      action = instance_double(ByteAction, buttons: [{ "status" => "pending" }])
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: action, auto_ran: false)

      run([{ tool_calls: [{ name: :create_chore, arguments: { "name" => "Mow", "reply" => "Logged that for you." } }] }])

      expect(reply.body).to eq("Logged that for you.")
    end

    it "retracts when the row came back failed rather than executed" do
      action = instance_double(ByteAction, buttons: [{ "status" => "failed" }])
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: action, auto_ran: false)

      run([{ tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes", "reply" => "That's logged." } }] }])

      expect(reply.body).to match(/couldn't quite line that one up/i)
    end

    it "does not touch ordinary conversation that claims nothing" do
      run([{ text: "Oof, that sounds like a rough one. How're you holding up?" }])

      expect(reply.body).to eq("Oof, that sounds like a rough one. How're you holding up?")
    end

    it "does not fire on an offer, which claims nothing" do
      run([{ text: "Want me to log that for you?" }])

      expect(reply.body).to eq("Want me to log that for you?")
    end

    it "does not fire on a plain warm acknowledgement" do
      run([{ text: "Nice, that counts. 💙" }])

      expect(reply.body).to eq("Nice, that counts. 💙")
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

  # A function call ENDS the model's turn — it writes no text alongside one and
  # expects the tool output back before saying anything. So every call has to be
  # answered, or an action turn produces an empty bubble. This was the bug that
  # made 13 of 16 eval scenarios come back with no prose.
  describe "giving the model a turn to speak after it calls a tool" do
    it "answers a proposal call and puts the follow-up prose in the reply" do
      client = run([
        { text: "", tool_calls: [{ name: :log_event, arguments: { "name" => "Sandwich" } }] },
        { text: "Nice, that counts." },
      ])

      expect(client.calls.length).to eq(2)
      expect(reply.body).to eq("Nice, that counts.")
    end

    it "answers a silent tool call so a mood-only turn still says something" do
      # "today was genuinely rough" used to set the face and return an empty
      # bubble, which is the worst possible moment for one.
      run([
        { text: "", tool_calls: [{ name: :set_mood, arguments: { "expression" => "sad" } }] },
        { text: "Oof. I'm sorry, that sounds like a lot." },
      ])

      expect(reply.body).to eq("Oof. I'm sorry, that sounds like a lot.")
      expect(convo.reload.buddy_expression).to eq("sad")
    end

    it "returns an output for every call in a round, not just the readable ones" do
      client = run([
        {
          text:       "",
          tool_calls: [
            { name: :get_context, call_id: "c1", arguments: { "sections" => ["chores_all"] } },
            { name: :set_mood,    call_id: "c2", arguments: { "expression" => "happy" } },
            { name: :log_event,   call_id: "c3", arguments: { "name" => "Coffee" } },
          ],
        },
        { text: "All set." },
      ])

      outputs = client.calls.last.input.select { |i| i[:type] == :function_call_output }
      expect(outputs.map { |o| o[:call_id] }).to contain_exactly("c1", "c2", "c3")
    end

    it "tells the model a pending proposal has NOT happened yet" do
      client = run([
        { text: "", tool_calls: [{ name: :create_chore, arguments: { "name" => "Mow" } }] },
        { text: "Want me to set that up?" },
      ])

      output = client.calls.last.input.find { |i| i[:type] == :function_call_output }
      expect(JSON.parse(output[:output])).to include("status" => "proposed")
      expect(output[:output]).to match(/do not say it's done/i)
    end

    it "tells the model an immediate action already happened" do
      client = run([
        { text: "", tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes" } }] },
        { text: "Nice, knocked out." },
      ])

      output = client.calls.last.input.find { |i| i[:type] == :function_call_output }
      # complete_chore is level 2: fires now, undoable.
      expect(JSON.parse(output[:output])).to include("status" => "done_undoable")
    end

    it "tells the model when it named a tool that does not exist" do
      client = run([
        { text: "", tool_calls: [{ name: :not_a_real_tool, arguments: {} }] },
        { text: "Sorry, I can't do that one." },
      ])

      output = client.calls.last.input.find { |i| i[:type] == :function_call_output }
      expect(JSON.parse(output[:output])).to include("ok" => false)
      expect(reply.body).to eq("Sorry, I can't do that one.")
    end

    it "only builds one checklist even when proposals arrive across rounds" do
      run([
        { text: "", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "", tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee" } }] },
        { text: "Done and done." },
      ])

      expect(ByteAction.where(byte_message_id: reply.id).count).to be <= 1
      expect(reply.body).to eq("Done and done.")
    end
  end

  # The reply field is what keeps an action turn to a single API call. Without it
  # every log/mood/proposal turn pays for a second round purely to collect prose.
  describe "prose riding on the tool call" do
    it "takes the reply off the call and answers in ONE round" do
      client = run([{
        tool_calls: [{ name: :log_event, arguments: { "name" => "Sandwich", "reply" => "Nice, sandwich fuel." } }],
      }])

      expect(client.calls.length).to eq(1)
      expect(reply.body).to eq("Nice, sandwich fuel.")
      expect(reply.state).to eq("delivered")
    end

    it "still builds the checklist from a single-round turn" do
      run([{
        tool_calls: [{ name: :create_chore, arguments: { "name" => "Mow the lawn", "reply" => "Sure, here:" } }],
      }])

      expect(ByteAction.find_by(byte_message_id: reply.id)).to be_present
      expect(reply.body).to eq("Sure, here:")
    end

    it "takes the FIRST non-blank reply when several calls carry one" do
      run([{
        tool_calls: [
          { name: :create_chore,   arguments: { "name" => "Spice rack", "reply" => "Setting that up." } },
          { name: :complete_chore, arguments: { "chore" => "Spice rack", "reply" => "And marking it done." } },
        ],
      }])

      expect(reply.body).to eq("Setting that up.")
    end

    it "skips the reply field entirely on a silent tool and still speaks" do
      run([{
        tool_calls: [{ name: :set_mood, arguments: { "expression" => "sad", "reply" => "Oof, I'm sorry." } }],
      }])

      expect(reply.body).to eq("Oof, I'm sorry.")
      expect(convo.reload.buddy_expression).to eq("sad")
    end

    it "never passes reply through to a tool's payload" do
      captured = nil
      allow(Buddy::ProposalBuilder).to receive(:create) { |args|
        captured = args[:markers].first[:payload]
        { action: nil, auto_ran: true }
      }

      run([{
        tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee", "reply" => "Logged it." } }],
      }])

      expect(captured).not_to have_key(:reply)
      expect(captured).to include(name: "Coffee")
    end

    it "still round-trips a read, because it cannot answer before seeing the data" do
      client = run([
        { tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "Nothing left on your list." },
      ])

      expect(client.calls.length).to eq(2)
      expect(reply.body).to eq("Nothing left on your list.")
    end

    it "feeds an inline reply back so the model does not repeat itself next round" do
      # Regression: only output_text was carried forward, so a round-1 inline
      # reply was invisible to round 2 and the model opened by saying it again.
      client = run([
        {
          tool_calls: [
            { name: :get_context, arguments: { "sections" => ["recent_events"] } },
            { name: :set_mood, arguments: { "expression" => "thinking", "reply" => "Oof, let me look." } },
          ],
        },
        { text: "Nothing there now." },
      ])

      carried = client.calls.last.input.select { |i| i[:role] == :assistant }
      expect(carried.last[:content]).to include("Oof, let me look.")
    end

    it "combines a read round's prose with a following action's inline reply" do
      # Subject here is how prose is stitched across rounds, so let the proposal
      # resolve — an unresolvable chore would (correctly) swap in the fallback.
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run([
        { text: "One sec.", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes", "reply" => "Dishes are done." } }] },
      ])

      expect(reply.body).to eq("One sec.\n\nDishes are done.")
    end

    it "falls back to a second round when the model leaves reply null everywhere" do
      client = run([
        { tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee" } }] },
        { text: "Got it." },
      ])

      expect(client.calls.length).to eq(2)
      expect(reply.body).to eq("Got it.")
    end
  end

  describe "round limit" do
    it "stops after the cap instead of looping forever" do
      rounds = Array.new(8) {
        { text: "checking", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] }
      }
      client = run(rounds)

      expect(client.calls.length).to eq(described_class::MAX_ROUNDS)
      expect(reply.state).to eq("delivered")
    end

    it "allows look-up, then act, then speak within the cap" do
      # Subject here is the round cap, so let the proposal resolve.
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      client = run([
        { text: "", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "", tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes" } }] },
        { text: "That's the dishes done." },
      ])

      expect(client.calls.length).to eq(3)
      expect(reply.body).to eq("That's the dishes done.")
    end
  end
end
