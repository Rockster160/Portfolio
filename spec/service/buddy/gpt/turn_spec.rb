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

  # Prod 1144: "3 more water done tonight." came back as "Yesss, counting three
  # more waters. Let me match that up." and then, below it, "Yessss, three waters
  # counted. Nice little hydration blob tonight." Two drafts of one reply. They
  # share almost no words, so no text comparison catches it - the fix is that
  # only the round which had the OUTCOME gets to speak.
  describe "when the model writes a lead-in before it acts" do
    it "shows only the round that spoke last" do
      run([
        {
          text:       "Yesss, counting three more waters. Let me match that up.",
          tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }],
        },
        { text: "Yessss, three waters counted." },
      ])

      expect(reply.body).to eq("Yessss, three waters counted.")
    end

    it "does not feed the discarded lead-in back, so the answer stands alone" do
      client = run([
        { text: "One sec.", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "Nothing left on your list." },
      ])

      carried = client.calls.last.input.select { |i| i[:role] == :assistant }
      expect(carried.pluck(:content)).not_to include("One sec.")
      expect(reply.body).to eq("Nothing left on your list.")
    end

    it "keeps the earlier line when the final round says nothing at all" do
      # Ran the budget out mid-chain. A stale lead-in still beats a blank bubble.
      run([
        {
          text:       "Let me take a look.",
          tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }],
        },
        { tool_calls: [{ name: :get_context, arguments: { "sections" => ["lists"] } }] },
      ])

      expect(reply.body).to eq("Let me take a look.")
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
      expect(reply.body).to eq(described_class::FALLBACK_BODY)
    end

    it "leaves the reply alone when something actually ran" do
      allow(described_class).to receive(:resolve_call).and_return([{ status: "done_undoable" }, nil])
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run([
        { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes" } }] },
        { text: "Nice, that's done." },
      ])

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
    # Subject here is what happens AFTER a call is built, so let every call
    # resolve cleanly and let each example stub what ProposalBuilder made of it.
    # Resolution failing has its own coverage further down.
    before { allow(described_class).to receive(:resolve_call).and_return([{ status: "proposed" }, nil]) }

    it "retracts a timer claim made with no tool call at all" do
      # Real prod bug: "5m" produced this with no set_timer call.
      run([{ text: "Kk! Timer's set for 5 minutes." }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "retracts a checking-that-off claim when the tool resolved to nothing" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: false)

      run([{ text: "You got it, checking that off." }])

      expect(reply.body).not_to match(/checking that off/i)
    end

    it "leaves the claim alone when a level-1 tool actually fired" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run([
        { tool_calls: [{ name: :schedule_reminder, arguments: { "text" => "call mom" } }] },
        { text: "Reminder's set for 6." },
      ])

      expect(reply.body).to eq("Reminder's set for 6.")
    end

    it "leaves the claim alone when a level-2 row came back executed" do
      action = instance_double(ByteAction, buttons: [{ "status" => "executed" }])
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: action, auto_ran: false)

      run([
        { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes" } }] },
        { text: "Nice, that's logged." },
      ])

      expect(reply.body).to eq("Nice, that's logged.")
    end

    it "leaves it alone when a pending row is visible, since the person can see it" do
      action = instance_double(ByteAction, buttons: [{ "status" => "pending" }])
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: action, auto_ran: false)

      run([
        { tool_calls: [{ name: :create_chore, arguments: { "name" => "Mow" } }] },
        { text: "Logged that for you." },
      ])

      expect(reply.body).to eq("Logged that for you.")
    end

    it "retracts when the row came back failed rather than executed" do
      action = instance_double(ByteAction, buttons: [{ "status" => "failed" }])
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: action, auto_ran: false)

      run([
        { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "dishes" } }] },
        { text: "That's logged." },
      ])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
    end

    # Prod 1146: "Turn the fan to low" came back "Done. Fan's on low now." off a
    # single API call - no tool use, no execution, nothing. The old pattern had
    # no notion of a bare "Done" or a device reported in its new state.
    # Prod 1151: "Set the fan to high" got a finished-sounding line off a single
    # call with no tool use. Retracting is honest but leaves the person with a
    # shrug where they asked for something, so the claim now buys one corrective
    # round first - the model is likelier to have skipped the call than to have
    # meant the claim.
    it "gives the model one more round to actually make the call" do
      # Claim with nothing behind it, then the nudge, then the call it skipped,
      # then the round it speaks in.
      client = run([
        { text: "Done. Fan's on high now." },
        { tool_calls: [{ name: :log_event, arguments: { "name" => "Fan high" } }] },
        { text: "Yep, fan's on high." },
      ])

      expect(client.calls.length).to eq(3)
      expect(client.calls[1].input.any? { |i| i[:content].to_s.include?("nothing happened") }).to be(true)
      expect(reply.body).to eq("Yep, fan's on high.")
    end

    it "retracts when the corrective round still calls nothing" do
      client = run([
        { text: "Done. Fan's on high now." },
        { text: "Done. Really this time." },
      ])

      expect(client.calls.length).to eq(2)
      expect(reply.body).to eq(described_class::FALLBACK_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "only ever spends one corrective round" do
      client = run(Array.new(5) { { text: "Done. Fan's on high now." } })

      expect(client.calls.length).to eq(2)
    end

    it "does not spend a round on ordinary conversation" do
      client = run([{ text: "Not much on my end, how's your night?" }])

      expect(client.calls.length).to eq(1)
    end

    # Prod 1313: "Which reminders do I have set up?" came back as "Here's what
    # you've got." (twice over, verbatim) off a single call with no tool use. The
    # list_reminders description had handed the model that exact sentence to use
    # as a lead-in, and it wrote the lead-in instead of making the call - leaving
    # a reply that points at a list nobody ever drew.
    it "gives the model a round when its whole reply points at output that isn't there" do
      client = run([
        { text: "Here's what you've got." },
        { tool_calls: [{ name: :list_reminders, arguments: {} }] },
        { text: "Two on the books right now." },
      ])

      expect(client.calls.length).to eq(3)
      expect(client.calls[1].input.any? { |i| i[:content].to_s.include?("lead-in") }).to be(true)
      # The lead-in is gone and the tool it was pointing at actually ran.
      bodies = convo.byte_messages.where(direction: :inbound).pluck(:body)
      expect(bodies).to include("Two on the books right now.")
      expect(bodies).not_to include("Here's what you've got.")
    end

    # The pointer has to be the WHOLE reply. A sentence that opens that way and
    # then says something real is ordinary conversation.
    it "leaves a pointer alone when a second clause follows it" do
      client = run([{ text: "Here's the thing, I can't reach the printer from here." }])

      expect(client.calls.length).to eq(1)
      expect(reply.body).to eq("Here's the thing, I can't reach the printer from here.")
    end

    it "does not spend a round when the claim is already backed by a call" do
      client = run([
        { tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee" } }] },
        { text: "Done, that's logged." },
      ])

      expect(client.calls.length).to eq(2)
      expect(reply.body).to eq("Done, that's logged.")
    end

    it "retracts a bare Done with nothing behind it" do
      run([{ text: "Done. Fan's on low now." }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "retracts a device reported in its new state" do
      run([{ text: "Yesss, lights are off now. 😊" }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
    end

    it "leaves an OFFER to change a device alone" do
      run([{ text: "I can set that to low if you want." }])

      expect(reply.body).to eq("I can set that to low if you want.")
    end

    it "leaves a question about a device alone" do
      run([{ text: "Is the fan on right now?" }])

      expect(reply.body).to eq("Is the fan on right now?")
    end

    it "retracts a promise to act that was never backed by a call" do
      # Real prod bug (1048): answered "you didn't add it to the Harmon's
      # category" with this, and called nothing.
      run([{ text: "Ah, gotcha. I'll fix that. Sanitizer for hike, in Harmon's." }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "retracts 'let me re-add it' with nothing behind it" do
      run([{ text: "Oh no, let me re-add that for you." }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
    end

    it "leaves a promise alone when the call actually accompanied it" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run([
        { tool_calls: [{ name: :add_list_item, arguments: { "list" => "Shopping", "item" => "milk" } }] },
        { text: "On it, adding that now." },
      ])

      expect(reply.body).to eq("On it, adding that now.")
    end

    it "does not fire on vague future intent, which is conversational" do
      run([{ text: "I'll keep an eye out for you." }])

      expect(reply.body).to eq("I'll keep an eye out for you.")
    end

    # Real prod bug (1106): "can you watch and let me know when the deploy
    # finishes?" got this reply with no remind_when call, so the deploy came and
    # went in silence. A promise to watch is broken exactly like a promise to
    # act - it just takes longer to notice.
    it "retracts a promise to watch for something that set no watch" do
      run([{ text: "You got it - I'll keep an eye on that." }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "retracts 'I'm watching for' with no watch behind it" do
      run([{ text: "Yep, I'm watching for the next deploy to finish." }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
    end

    it "retracts a promise to notify when a future event happens" do
      run([{ text: "Sure thing, I'll let you know when it lands." }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
    end

    it "leaves the watch promise alone once remind_when actually fired" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run([
        { tool_calls: [{ name: :remind_when, arguments: { "trigger" => "deploy", "body" => "deploy done" } }] },
        { text: "You got it - I'll keep an eye on that." },
      ])

      expect(reply.body).to eq("You got it - I'll keep an eye on that.")
    end

    it "does not fire on a bare 'I'll let you know', which is small talk" do
      run([{ text: "Sounds good. I'll let you know." }])

      expect(reply.body).to eq("Sounds good. I'll let you know.")
    end

    it "does not fire on a promise that is waiting on an answer" do
      # Asking which item before fixing it is the RIGHT move on an ambiguous
      # reference; retracting it would replace a good clarifying question.
      run([{ text: "Oof, my bad. Tell me which item it was and I'll fix it." }])

      expect(reply.body).to eq("Oof, my bad. Tell me which item it was and I'll fix it.")
    end

    it "still retracts a past-tense claim even when a question trails it" do
      run([{ text: "Logged that for you. Anything else on your mind?" }])

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
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

      expect(reply.body).to eq(described_class::FALLBACK_BODY)
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
    # Deliberately not a completion claim - "Done." on its own is retracted now,
    # which would mask what this is actually testing.
    it "strips a marker the model emitted anyway rather than showing brackets" do
      run([{ text: "Good to hear. [[mood: happy]]" }])

      expect(reply.body).to eq("Good to hear.")
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
        { text: "", tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee" } }] },
        { text: "Nice, knocked out." },
      ])

      output = client.calls.last.input.find { |i| i[:type] == :function_call_output }
      # log_event is level 2: fires now, undoable.
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

  # Call, then speak. The model stays quiet while it's calling something, we
  # resolve the call, and it writes its reply on the round after with the outcome
  # in hand. Prose used to ride on the call itself to save the second request,
  # but that meant writing the words BEFORE knowing whether the thing resolved.
  describe "the call-then-speak flow" do
    it "answers in ONE call when no tool is needed" do
      client = run([{ text: "Not much on my end, how's your night?" }])

      expect(client.calls.length).to eq(1)
      expect(reply.body).to eq("Not much on my end, how's your night?")
    end

    it "spends a second call to speak after an action" do
      client = run([
        { tool_calls: [{ name: :log_event, arguments: { "name" => "Sandwich" } }] },
        { text: "Nice, sandwich fuel." },
      ])

      expect(client.calls.length).to eq(2)
      expect(reply.body).to eq("Nice, sandwich fuel.")
      expect(reply.state).to eq("delivered")
    end

    it "still builds the checklist off the round that called the tool" do
      run([
        { tool_calls: [{ name: :create_chore, arguments: { "name" => "Mow the lawn" } }] },
        { text: "Sure, here you go:" },
      ])

      expect(ByteAction.find_by(byte_message_id: reply.id)).to be_present
      expect(reply.body).to eq("Sure, here you go:")
    end

    it "runs a silent tool as its call arrives and speaks on the round after" do
      run([
        { tool_calls: [{ name: :set_mood, arguments: { "expression" => "sad" } }] },
        { text: "Oof, I'm sorry." },
      ])

      expect(reply.body).to eq("Oof, I'm sorry.")
      expect(convo.reload.buddy_expression).to eq("sad")
    end

    it "answers from the round that saw the tool output, not the one before it" do
      run([
        { tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "Nothing left on your list." },
      ])

      expect(reply.body).to eq("Nothing left on your list.")
    end
  end

  # The whole point of paying for the second call: the model learns what the tool
  # actually resolved to BEFORE it writes a word. A chore name matching nothing
  # used to be dropped in silence under prose that had already claimed credit.
  describe "resolving the call before the model speaks" do
    it "hands back the resolved summary when the tool lines up" do
      client = run([
        { tool_calls: [{ name: :create_chore, arguments: { "name" => "Dust shelves" } }] },
        { text: "Here you go:" },
      ])

      output = client.calls.last.input.find { |i| i[:type] == :function_call_output }
      expect(JSON.parse(output[:output])).to include("status" => "proposed")
      expect(output[:output]).to include("Dust shelves")
    end

    it "reports a failure when the named thing resolves to nothing" do
      client = run([
        { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "a chore that does not exist" } }] },
        { text: "I couldn't find a chore by that name - which one did you mean?" },
      ])

      output = JSON.parse(client.calls.last.input.find { |i| i[:type] == :function_call_output }[:output])
      expect(output["status"]).to eq("failed")
      expect(output["note"]).to match(/did NOT happen/i)
      expect(reply.body).to match(/couldn't find a chore/i)
    end

    it "reports a failure when a required argument is missing" do
      client = run([
        { tool_calls: [{ name: :log_event, arguments: {} }] },
        { text: "What should I call it?" },
      ])

      output = JSON.parse(client.calls.last.input.find { |i| i[:type] == :function_call_output }[:output])
      expect(output["status"]).to eq("failed")
    end

    # "just got back from a walk with the puppy" reliably produced complete_chore
    # with `at: "now"` and then again a round later with `at: null`. Both resolve
    # to the same chore, complete_chore is level 2 so both execute on arrival,
    # and one walk quietly earned two completions.
    it "ignores a call the model repeats in a later round" do
      captured = nil
      allow(Buddy::ProposalBuilder).to receive(:create) { |args|
        captured = args[:markers]
        { action: nil, auto_ran: true }
      }

      run([
        { tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee", "at" => "now" } }] },
        { tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee" } }] },
        { text: "Got it." },
      ])

      expect(captured.length).to eq(1)
    end

    it "tells the model its repeat was ignored rather than silently dropping it" do
      client = run([
        { tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee" } }] },
        { tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee" } }] },
        { text: "Got it." },
      ])

      output = JSON.parse(client.calls.last.input.select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["status"]).to eq("duplicate")
      expect(output["note"]).to match(/already called this/i)
    end

    # The same call twice in ONE round is the model asking for two of something,
    # which ProposalBuilder collapses into a single row with count 2.
    it "keeps two identical calls made in the same round" do
      captured = nil
      allow(Buddy::ProposalBuilder).to receive(:create) { |args|
        captured = args[:markers]
        { action: nil, auto_ran: true }
      }

      run([
        {
          tool_calls: [
            { name: :log_event, call_id: "a", arguments: { "name" => "Coffee" } },
            { name: :log_event, call_id: "b", arguments: { "name" => "Coffee" } },
          ],
        },
        { text: "Two coffees, noted." },
      ])

      expect(captured.length).to eq(2)
    end

    it "resolves without executing, so nothing lands until the checklist runs" do
      run([
        { tool_calls: [{ name: :create_chore, arguments: { "name" => "Never actually created" } }] },
        { text: "Tap when you're ready." },
      ])

      expect(Chore.where(name: "Never actually created")).not_to exist
    end
  end

  # A reminder firing, a watch tripping, the morning briefing: all arrive as a
  # hidden buddy_trigger seed, and the reply to one must not be silenced by
  # presence the way ordinary back-and-forth is. ByteNotifier can't see the seed
  # by then, so the flag has to ride on the reply.
  describe "replies to something Buddy started itself" do
    def trigger_says(text)
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: text,
        metadata: { "kind" => "buddy_trigger", "hidden" => true, "source" => "watch" },
      )
    end

    def fires(text, rounds)
      client = FakeBuddyClient.new(rounds)
      described_class.run!(trigger_says(text), client: client)
      client
    end

    it "marks the reply self-initiated" do
      fires("[nothing was said to you] put your Loops away", [{ text: "Loops away, friend." }])

      expect(reply.metadata["self_initiated"]).to be(true)
    end

    it "leaves the flag off an ordinary reply rather than stamping every one" do
      run([{ text: "Not much on my end." }])

      expect(reply.metadata).not_to have_key("self_initiated")
    end

    # Prod 1319. The same deploy watch tripped twice 45 minutes apart, and the
    # model found its own announcement of the first one in history and decided
    # the second was a duplicate. That reply was the push notification, so the
    # deploy it fired for was never mentioned to anyone.
    it "gives the model a round when it waves off news nobody has heard yet" do
      client = fires("[nothing was said to you] The deploy just finished successfully.", [
        { text: "Already handled that one just now. Nothing new is waiting on my side." },
        { text: "Deploy's through clean." },
      ])

      expect(client.calls.length).to eq(2)
      expect(client.calls[1].input.any? { |i| i[:content].to_s.include?("Nobody spoke to you") }).to be(true)
      expect(reply.body).to eq("Deploy's through clean.")
    end

    it "leaves the same sentence alone when a person actually asked" do
      client = run([{ text: "Already handled that one just now." }], text: "did you get the trash out?")

      expect(client.calls.length).to eq(1)
      expect(reply.body).to eq("Already handled that one just now.")
    end

    it "spends no round when the trigger got the announcement it fired for" do
      client = fires("[nothing was said to you] The deploy just finished successfully.", [
        { text: "Deploy landed clean a second ago." },
      ])

      expect(client.calls.length).to eq(1)
    end
  end

  describe "the turn budget" do
    it "hands every round the same deadline, so round-trips can't multiply it" do
      # Deliberately not a completion claim - that would earn a corrective round
      # and a third call, which isn't what this is measuring.
      client = run([
        { text: "", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "You've got three left." },
      ])

      deadlines = client.calls.map(&:deadline)
      expect(deadlines.compact.length).to eq(2)
      expect(deadlines.uniq.length).to eq(1)
    end

    it "sets the deadline inside the dispatcher's lock wait, so a slow turn can't outlast it" do
      expect(described_class::TURN_BUDGET_SECONDS).to be < Buddy::TurnDispatcher::LOCK_WAIT_SECONDS
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
