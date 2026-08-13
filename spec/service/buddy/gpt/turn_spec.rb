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

  # The Today seed carries `buddy_action: "today"`, and that marker is the only
  # thing standing between the briefing and the full chore roster. Wiring it
  # through was the entire fix, so it gets asserted at the turn rather than
  # only on the tool: the previous attempt added `chores_due_today` to the
  # context and never exposed it through get_context, so nothing changed at all.
  describe "the Today briefing turn" do
    def turn_for(metadata)
      message = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "what's on today", metadata: metadata,
      )
      described_class.new(message, client: FakeBuddyClient.new([]))
    end

    def offered_sections(turn)
      turn.send(:tools).first.dig(:parameters, :properties, :sections, :items, :enum)
    end

    it "offers the briefing only the due-today chores" do
      turn = turn_for({ "kind" => "buddy_trigger", "buddy_action" => "today" })

      expect(offered_sections(turn).grep(/\Achores_/)).to eq([:chores_due_today])
    end

    it "hands the same narrowing to the tool that answers the call" do
      turn = turn_for({ "kind" => "buddy_trigger", "buddy_action" => "today" })

      returned = JSON.parse(turn.send(:read_tools)[Buddy::GPT::ContextTool::NAME].call({}))

      expect(returned.keys.grep(/\Achores_/)).to eq(["chores_due_today"])
    end

    it "leaves an ordinary message with the whole roster" do
      turn = turn_for({})

      expect(offered_sections(turn)).to include(:chores_pending_today, :chores_all)
    end

    # A different quick action is not a briefing, and narrowing one would be a
    # silent hole in whatever it was asked to do.
    it "leaves another quick action alone" do
      turn = turn_for({ "kind" => "buddy_trigger", "buddy_action" => "checkin" })

      expect(offered_sections(turn)).to include(:chores_pending_today)
    end
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

    it "sets the face from a leading [[mood:]] marker and strips it from the body" do
      run([{ text: "[[mood:sad]] Oh no, that's rough." }])

      expect(convo.reload.buddy_expression).to eq("sad")
      expect(reply.body).to eq("Oh no, that's rough.")
    end

    it "drops a leading marker naming a face the theme can't render, keeping the body" do
      run([{ text: "[[mood:celebrating]] Woo!" }])

      expect(convo.reload.buddy_expression).to eq("happy") # unchanged
      expect(reply.body).to eq("Woo!")
    end

    # The whole reason for the marker over the set_mood tool: the face has to
    # reach the screen with (or before) the words, not a beat behind them.
    it "broadcasts the face before the reply body" do
      kinds = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_user, payload| kinds << payload[:data][:kind] }

      run([{ text: "[[mood:sad]] Sitting with you on that one." }])

      expect(kinds).to include(:buddy_expression)
      expect(kinds.index(:buddy_expression)).to be < kinds.rindex(:message)
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

    # Prod 1439/1440. Asked to pass a line to Chelsea, the model answered
    # "Sent. 😅" and then WROTE OUT the `[you passed this along to Moss]`
    # attribution that History puts on bridged messages so Buddy can read them.
    # No message_partner call, no relay row, no receipt chip - and neither guard
    # fired, because "Sent." matched no claim pattern and the bracket was only
    # ever checked for the retired `[[marker]]` syntax.
    describe "a relay it only described" do
      let(:faked) { "Sent. 😅\n\n[you passed this along to Moss] Rude. Byte took away my formatting!" }

      it "gets one corrective round to actually make the call" do
        allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

        client = run([
          { text: faked },
          { tool_calls: [{ name: :message_partner, arguments: { "to" => "Chelsea", "message" => "Rude." } }] },
          { text: "Okay, that one's actually on its way." },
        ])

        expect(client.calls[1].input.last[:content]).to eq(described_class::RETRY_NUDGE)
        expect(reply.body).to eq("Okay, that one's actually on its way.")
      end

      it "retracts rather than showing a send that never happened" do
        allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: false)

        run([{ text: faked }, { text: faked }])

        expect(reply.body).to eq(described_class::FALLBACK_BODY)
        expect(reply.metadata["retracted_claim"]).to be(true)
      end

      # Defense in depth: even when something legitimately ran this turn, the
      # attribution is input framing and must never reach the person.
      it "strips the attribution out of a reply that survives" do
        allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

        run([
          { tool_calls: [{ name: :message_partner, arguments: { "to" => "Chelsea", "message" => "Rude." } }] },
          { text: "[you passed this along to Moss] Rude. Byte took away my formatting!" },
        ])

        expect(reply.body).to eq("Rude. Byte took away my formatting!")
      end
    end

    # Prod 3171: "I pulled the front flower bed reminder down so it won't keep
    # bugging you!" over an untapped cancel_reminder. A pending row used to
    # exempt the claim entirely on the grounds that the checkbox speaks for
    # itself - but a sentence saying it's already handled is the reason nobody
    # looks at the checkbox. It fired again at 8am the next morning.
    describe "a claim standing over a row that is only PROPOSED" do
      let(:action) { instance_double(ByteAction, buttons: [{ "status" => "pending" }]) }

      before { allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: action, auto_ran: false) }

      it "corrects the tense instead of letting it stand" do
        run([
          { tool_calls: [{ name: :create_chore, arguments: { "name" => "Mow" } }] },
          { text: "Logged that for you." },
        ])

        expect(reply.body).to eq(described_class::PENDING_BODY)
        expect(reply.metadata["retracted_claim"]).to be(true)
      end

      it "points at the row rather than saying nothing ran, since something is there" do
        run([
          { tool_calls: [{ name: :cancel_reminder, arguments: { "match" => "26" } }] },
          { text: "Aroo, perfect call then!! I pulled the front flower bed reminder down so it won't keep bugging you!" },
        ])

        expect(reply.body).to eq(described_class::PENDING_BODY)
        expect(reply.body).not_to eq(described_class::UNDONE_BODY)
      end

      # The :commanded arm infers the failure from the REQUEST being an
      # imperative. A proposal waiting on screen IS an answer to one, so an
      # honest reply offering it must survive untouched.
      it "leaves an honest offer alone" do
        run(
          [
            { tool_calls: [{ name: :cancel_reminder, arguments: { "match" => "26" } }] },
            { text: "Kk! Here's that one ready to go, tap it below." },
          ],
          text: "cancel my 8am reminder",
        )

        expect(reply.body).to eq("Kk! Here's that one ready to go, tap it below.")
        expect(reply.metadata["retracted_claim"]).to be_nil
      end
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

    # Prod 2054: "Print again" got "Yep. Running the last print again." with no
    # call, and then, when told it hadn't, "Yep, it's running again now." — also
    # with no call. The pattern only covered the emphasised receipt shape
    # ("Firing **Fan High**"), so plain prose walked past it twice.
    describe "a plain-prose claim to have run something" do
      it "retracts the one from prod" do
        run([{ text: "Yep. Running the last print again." }])

        expect(reply.body).to eq(described_class::FALLBACK_BODY)
        expect(reply.metadata["retracted_claim"]).to be(true)
      end

      it "retracts the doubled-down follow-up too" do
        run([{ text: "Yep, it’s running again now." }])

        expect(reply.body).to eq(described_class::FALLBACK_BODY)
      end

      it "leaves it alone once the function actually fired" do
        allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

        run([
          { tool_calls: [{ name: :call_jil_function, arguments: { "name" => "Print Again" } }] },
          { text: "Yep. Running the last print again." },
        ])

        expect(reply.body).to eq("Yep. Running the last print again.")
      end

      # `running` is far too ordinary a word to match loose, and a false
      # positive here replaces a perfectly good reply with the fallback. These
      # are the shapes the anchoring and the required object exist to protect.
      {
        "running late"        => "I’m running late, sorry.",
        "running low"         => "You’re running low on milk.",
        "a device running"    => "The dishwasher is running.",
        "a question"          => "Is the print still running?",
        "someone else's verb" => "Looks like the printer is running the last job.",
        "a past observation"  => "That’s still running from earlier, want me to check?",
        "an offer"            => "Want me to run that again?",
      }.each do |label, text|
        it "leaves #{label} alone" do
          run([{ text: text }])

          expect(reply.body).to eq(text)
        end
      end
    end

    # Everything else in the claim pattern is about a thing being added, set,
    # logged or run. Taking a thing AWAY had no coverage at all, and it's the
    # half nobody notices has failed: an unwanted reminder that keeps arriving
    # reads as the system working normally. Prod 3171 is the one that got out.
    describe "a claim to have cancelled something" do
      {
        "the one from prod" => "I pulled the front flower bed reminder down so it won't keep bugging you!",
        "a plain cancel"    => "Cancelled that for you.",
        "a removal"         => "Removed it from your reminders.",
        "took it off"       => "Took that off the schedule.",
        "a named removal"   => "I pulled the 8am reminder off for you.",
        "it's cancelled"    => "That’s cancelled now.",
        "the reassurance"   => "It won’t bug you again.",
      }.each do |label, text|
        it "retracts #{label}" do
          run([{ text: text }])

          expect(reply.body).to eq(described_class::FALLBACK_BODY)
          expect(reply.metadata["retracted_claim"]).to be(true)
        end
      end

      it "leaves it alone once the cancel actually ran" do
        allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

        run([
          { tool_calls: [{ name: :cancel_reminder, arguments: { "match" => "26" } }] },
          { text: "Cancelled that for you." },
        ])

        expect(reply.body).to eq("Cancelled that for you.")
      end

      # An offer to remove something is the normal way this conversation starts,
      # and rewriting one would replace a good reply with a shrug.
      {
        "an offer"          => "Want me to cancel that one?",
        "a capability"      => "I can remove that if you'd rather.",
        "a question back"   => "Which reminder should I delete?",
        "reading something" => "I pulled up your reminders, there are three.",
        "an ordinary pull"  => "I pulled the numbers for last month.",
        # The one that broke the prompt-tools spec: `the` plus any noun plus a
        # particle is far too much of the language to claim.
        "an errand"         => "Eve took the puppy out - check it over and send it.",
        "a plain removal"   => "Chelsea took the trash out already.",
        "an honest limit"   => "I won’t remind you unless you ask me to.",
      }.each do |label, text|
        it "leaves #{label} alone" do
          run([{ text: text }])

          expect(reply.body).to eq(text)
        end
      end
    end

    # Everything above is a thing being added, set, logged, run or taken away.
    # None of it covers a thing being CHANGED, which is what a correction always
    # is — and a correction is the one place a claim is most likely to be
    # written instead of made, because the person has just said what's wrong and
    # agreeing is the obvious reply. Prod 3509-3510: "the script was supposed to
    # be darkness, NOT total darkness" got "Kk! I fixed the script wording to
    # darkness." and buddy_routines 4 still read total_darkness.
    describe "a claim to have CHANGED something" do
      {
        "the one from prod" => "Kk! I fixed the script wording to darkness.",
        "a correction"      => "I corrected that for you.",
        "an update"         => "I updated the list just now.",
        "a rename"          => "I renamed that to Wrist White Board.",
        "a swap"            => "I swapped the scene over.",
        "the perfect tense" => "I’ve changed the wording on that one.",
      }.each do |label, text|
        it "retracts #{label}" do
          run([{ text: text }])

          expect(reply.body).to eq(described_class::FALLBACK_BODY)
          expect(reply.metadata["retracted_claim"]).to be(true)
        end
      end

      it "leaves it alone once the edit actually ran" do
        allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

        run([
          { tool_calls: [{ name: :edit_routine, arguments: { "name" => "lockdown", "step" => 2, "set" => "{}" } }] },
          { text: "Kk! I fixed the script wording to darkness." },
        ])

        expect(reply.body).to eq("Kk! I fixed the script wording to darkness.")
      end

      # First person and past tense are both load-bearing: a bare verb is far
      # too much of the language to claim.
      {
        "a change of mind"    => "I’ve changed my mind about that one.",
        "someone else's verb" => "Chelsea updated the shopping list already.",
        "an offer"            => "Want me to fix the wording?",
        "an intransitive one" => "That changed everything, honestly.",
        "a question"          => "Did you change the scene on that?",
        "an observation"      => "The scene changed when the blinds closed.",
      }.each do |label, text|
        it "leaves #{label} alone" do
          run([{ text: text }])

          expect(reply.body).to eq(text)
        end
      end
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

  # The reply's own words cannot settle this one. Prod 3229: "Turn the tv off"
  # was answered "Kk! TV's off." with no tool call and nothing run, and no rule
  # above fires on that sentence — because it is ALSO the correct answer to "is
  # the TV on?", where nothing should have run. What tells them apart is the
  # request: an imperative orders a thing to happen; a question doesn't.
  describe "a command that nothing was called for" do
    before { allow(described_class).to receive(:resolve_call).and_return([{ status: "proposed" }, nil]) }

    it "gets one corrective round, so the thing might still get done" do
      client = run(
        [
          { text: "Kk! TV’s off." },
          { tool_calls: [{ name: :call_jil_function, arguments: { "name" => "HASS TV", "args" => ["off"] } }] },
          { text: "Kk! TV’s off." },
        ],
        text: "Turn the tv off",
      )

      expect(client.calls.length).to be >= 2
      expect(reply.body).to eq("Kk! TV’s off.")
    end

    it "owns it plainly when the corrective round still calls nothing" do
      run([{ text: "Kk! TV’s off." }, { text: "Kk! TV’s off." }], text: "Turn the tv off")

      expect(reply.body).to eq(described_class::UNDONE_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "says it didn't happen rather than that it didn't understand" do
      run([{ text: "Kk! lights are off." }, { text: "Kk! lights are off." }], text: "turn the lights off")

      expect(reply.body).not_to eq(described_class::FALLBACK_BODY)
      expect(reply.body).to include("wasn't")
    end

    # The three ways a command legitimately ends with nothing run.
    it "leaves an honest refusal alone" do
      said = "I can't reach the TV from here - it isn't wired up to anything I can call."
      run([{ text: said }], text: "Turn the tv off")

      expect(reply.body).to eq(said)
    end

    it "leaves a clarifying question alone" do
      said = "Which one - the living room TV or the bedroom one?"
      run([{ text: said }], text: "Turn the tv off")

      expect(reply.body).to eq(said)
    end

    it "does not fire when the command was actually carried out" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)

      run(
        [
          { tool_calls: [{ name: :call_jil_function, arguments: { "name" => "HASS TV", "args" => ["off"] } }] },
          { text: "Kk! TV’s off." },
        ],
        text: "Turn the tv off",
      )

      expect(reply.body).to eq("Kk! TV’s off.")
    end

    # A QUESTION about the same device reads identically in the reply, and
    # nothing running is the correct outcome. This is the case that stops the
    # claim regex being widened instead.
    it "leaves the same sentence alone when they only asked" do
      run([{ text: "Kk! TV’s off." }], text: "is the tv on?")

      expect(reply.body).to eq("Kk! TV’s off.")
    end

    it "leaves a statement that merely mentions a command word alone" do
      said = "Ha, fair. Mornings are rough."
      run([{ text: said }], text: "I need to start running again")

      expect(reply.body).to eq(said)
    end

    # Opens with a command verb and is a turn of phrase. What follows the verb
    # is the difference: an order names a thing, this names a preposition.
    it "leaves conversational phrasing that opens with a command verb alone" do
      said = "Sounds good, the milk first then."
      run([{ text: said }], text: "start with the milk")

      expect(reply.body).to eq(said)
    end

    # Prod 3236, and prod 2054 twice before it. Every earlier round patched the
    # claim regex and the next occurrence dodged it by renaming the noun, so
    # this is asserted from the REQUEST side, which can't be reworded away.
    it "catches a print that never ran, however the reply phrases it" do
      said = "Yessss, the printer’s running the last file again. `game_tray-vase-40M.gcode`."
      run([{ text: said }, { text: said }], text: "print again")

      expect(reply.body).to eq(described_class::UNDONE_BODY)
    end

    it "catches the other wording of the same fabricated receipt" do
      run(
        [{ text: "Printing `game_tray-vase-40M.gcode` again." }] * 2,
        text: "Print game tray",
      )

      expect(reply.body).to eq(described_class::UNDONE_BODY)
    end

    it "leaves an ordinary sentence about printing alone when they didn't order one" do
      said = "Sounds like the printer’s been busy!"
      run([{ text: said }], text: "the printer has been going all day")

      expect(reply.body).to eq(said)
    end
  end

  # Prod 3128: "Good night" got "Total darkness, and the monitors are out.
  # *click* 💙" off a single call with nothing run. No verb to catch on the
  # request side, and no noun the claim regex knew — but the sound effect is
  # Byte's own, and in every one of its 18 prod appearances it sat on a claim
  # about a device.
  describe "the *click*" do
    before { allow(described_class).to receive(:resolve_call).and_return([{ status: "proposed" }, nil]) }

    it "gets retracted when nothing ran" do
      said = "Good night! Total darkness, and the monitors are out. *click* 💙"
      run([{ text: said }, { text: said }], text: "Good night")

      expect(reply.body).to eq(described_class::UNDONE_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    # The same sentence, correctly, with nothing run: they asked what the state
    # was rather than telling Buddy to change it.
    it "stands when they only asked whether it was done" do
      said = "Yep — lights are off. *click*"
      run([{ text: said }], text: "did you turn the lights off?")

      expect(reply.body).to eq(said)
    end

    it "stands on a bare state question with no question mark" do
      said = "Monitors are out. *click*"
      run([{ text: said }], text: "are the monitors off")

      expect(reply.body).to eq(said)
    end

    it "stands when the thing actually ran" do
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)
      said = "Kk! Monitors are out. *click*"
      run(
        [
          { tool_calls: [{ name: :mac_command, arguments: { "command" => "dark_monitors" } }] },
          { text: said },
        ],
        text: "Good night",
      )

      expect(reply.body).to eq(said)
    end
  end

  # Aug 11: Suki opened "Mooooorning!" and Moss "Good morning!", and Byte, off
  # the identical seed, opened "Pretty quiet day on your side."
  #
  # Four rounds of prompt wording failed at this, then a corrective round did
  # too — prod 3398 opened "Light day on your side so far." on a seed that
  # said OPEN WITH A GREETING, because the corrective round is one shot shared
  # with five other arms and something else had already spent it. So the hello
  # is no longer requested: if the reply doesn't have one, one goes on the
  # front, in the pet's own words.
  describe "a briefing that opens cold" do
    def briefing(rounds, seed: Buddy::TodayBriefing.seed(user))
      message = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: seed,
        metadata: { "kind" => "buddy_trigger", "hidden" => true, "buddy_action" => "today" }
      )
      client = FakeBuddyClient.new(rounds)
      described_class.run!(message, client: client)
      client
    end

    it "has one put on the front, without spending another round on it" do
      cold   = "Pretty quiet day on your side. The only thing I see is a noon supply run."
      client = briefing([{ text: cold }])

      expect(client.calls.length).to eq(1)
      expect(reply.body).to end_with(cold)
      expect(reply.body).not_to eq(cold)
    end

    # Whatever went on the front has to be a hello by the same test that found
    # it missing, or the fallback is decoration.
    it "puts on something that actually reads as a greeting" do
      briefing([{ text: "Pretty quiet day on your side." }])

      expect(reply.body).to match(described_class::GREETING_OPENER_RX)
    end

    it "takes the words from the pet whose thread it is" do
      briefing([{ text: "Pretty quiet day on your side." }])

      said = Buddy::VoiceLines.lines_for(convo.buddy_theme, Buddy::TodayBriefing.greeting_kind(user)).pluck(:say)
      expect(said.any? { |hello| reply.body.start_with?(hello) }).to be(true)
    end

    it "leaves a briefing that already greeted alone" do
      client = briefing([{ text: "Hey hey, Rocco! Quiet one today, just the noon run." }])

      expect(client.calls.length).to eq(1)
      expect(reply.body).to start_with("Hey hey, Rocco!")
    end

    # Mid-conversation is still a Today, and a Today opens with a hello.
    it "greets even when they were talking a moment ago" do
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "what's up", created_at: 2.minutes.ago,
      )
      briefing([{ text: "Quiet one today, just the noon run." }])

      expect(reply.body).to match(described_class::GREETING_OPENER_RX)
    end

    # The seed is what says a hello was wanted. If somebody edits that directive
    # out, the fallback has to stop rather than argue with the prompt.
    it "puts nothing on a briefing whose seed never asked" do
      client = briefing([{ text: "Quiet one today." }], seed: "What's on for TODAY, forward-looking.")

      expect(client.calls.length).to eq(1)
      expect(reply.body).to eq("Quiet one today.")
    end

    it "leaves ordinary turns alone" do
      client = run([{ text: "Quiet one today." }], text: "how's the day looking")

      expect(client.calls.length).to eq(1)
    end

    # The tone profiles ask for stretched, varied openers, so the check has to
    # accept them or it would fight the instruction it's enforcing.
    it "accepts every shape of hello the personas actually write" do
      [
        "Mooooorning! ",
        "Good morning! ",
        "Morning! ",
        "Hey hey, Rocco! ",
        "Hellooooooo there. ",
        "Hiii! ",
        "Well hello! ",
        "Good evening. ",
        "Howdy! ",
        "☀️ Morning! ",
        "Happy Tuesday! ",
        "[[mood:happy]]Hey there! ",
      ].each { |opener|
        body = opener.sub(described_class::LEADING_MOOD_RX, "")
        expect(body).to match(described_class::GREETING_OPENER_RX), "expected #{opener.inspect} to read as a greeting"
      }
    end

    it "does not mistake the news for a hello" do
      [
        "Pretty quiet day on your side.",
        "You've got a few chores sitting up today.",
        "Good little start. The big one on deck is Cymbalta.",
        "Nothing pressing today.",
      ].each { |body|
        expect(body).not_to match(described_class::GREETING_OPENER_RX)
      }
    end
  end

  # Prod 3229 again, the other half: the same sentence twice in one bubble.
  describe "a reply that repeats itself" do
    it "says it once when the model wrote it twice in one part" do
      run([{ text: "Kk! TV’s off.\n\nKk! TV’s off." }], text: "what's up")

      expect(reply.body).to eq("Kk! TV’s off.")
    end

    # The client already drops a verbatim repeat across message parts, but it
    # compares them BEFORE the mood marker is stripped — so this pair got past
    # it and only became identical on the way to the screen.
    it "says it once when the copies differed only by a mood marker" do
      run([{ text: "[[mood:uwu]]Kk! TV’s off.\n\nKk! TV’s off." }], text: "what's up")

      expect(reply.body).to eq("Kk! TV’s off.")
    end

    it "keeps two paragraphs that actually say different things" do
      run([{ text: "First thing.\n\nSecond thing." }], text: "what's up")

      expect(reply.body).to eq("First thing.\n\nSecond thing.")
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

    it "does not leak genuinely-retired marker protocols into the prompt" do
      client = run([{ text: "ok" }])

      expect(client.calls.first.instructions).not_to include("[[propose:")
    end

    it "teaches the leading mood marker (the live face protocol)" do
      client = run([{ text: "ok" }])

      expect(client.calls.first.instructions).to include("[[mood:")
    end
  end

  # An image's pixels are sent once, on the turn it arrives, and every replay
  # after that is just its filename - so view_image is the only way back to a
  # picture. A function_call_output is a STRING and can't carry one, which is
  # why the tool stages a user item for Turn to splice in behind the output.
  describe "re-opening an image the person sent earlier" do
    before { ActiveStorage::Current.url_options = { host: "example.com", protocol: "https" } }
    after  { ActiveStorage::Current.url_options = nil }

    it "puts the pixels back on the input for the round that follows the call" do
      old = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "look")
      old.files.attach(io: StringIO.new("png-bytes"), filename: "chart.png", content_type: "image/png")

      client = run(
        [
          { tool_calls: [{ name: :view_image, arguments: { "message_id" => old.id } }] },
          { text: "Top left says 42." },
        ],
        text: "what was the number again?",
      )

      # Round one only names it; round two is where it can actually be seen.
      expect(client.calls.first.input.to_s).not_to include("input_image")
      reopened = client.calls.last.input.last
      expect(reopened[:role]).to eq(:user)
      expect(reopened[:content].pluck(:type)).to eq([:input_text, :input_image])
      expect(reply.body).to eq("Top left says 42.")
    end

    it "offers the tool alongside the other read tools" do
      client = run([{ text: "ok" }])

      expect(client.calls.first.tools.pluck(:name)).to include(:view_image)
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
      ActionEvent.create!(user: user, name: "Mow", timestamp: Time.current)
      client = run([
        { text: "", tool_calls: [{ name: :edit_event, arguments: { "event" => "Mow", "notes" => "front yard" } }] },
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
  # An answering tool settles INSIDE the turn. These used to be ordinary
  # level-1 tools, which meant they executed after the reply was already written
  # and fed their findings into a whole second turn — so on the turn that
  # mattered the model held only "Ran immediately. Speak about it as done." and
  # no data. It filled the gap with a guess. Prod 2710: "No print record for
  # `game_tray-vase` either", followed four seconds later by prod 2712: "Found
  # it."
  describe "a tool that answers in-turn" do
    def print!(name, at: 2.hours.ago)
      start = ActionEvent.create!(
        user: user, name: "PrintStart", notes: name, timestamp: at,
        data: { estimated_seconds: 2400 }
      )
      ActionEvent.create!(
        user: user, name: "PrintFinish", notes: name, timestamp: at + 40.minutes,
        data: { start_event_id: start.id, actual_seconds: 2400 }
      )
    end

    def output_of(client)
      JSON.parse(client.calls.last.input.find { |i| i[:type] == :function_call_output }[:output])
    end

    it "puts the findings in front of the model before it writes a word" do
      print!("game_tray-vase")

      client = run([
        { tool_calls: [{ name: :print_history, arguments: { "query" => "game tray" } }] },
        { text: "That's `game_tray-vase`, finished this morning." },
      ])

      output = output_of(client)
      expect(output["status"]).to eq("answered")
      expect(output["prints"].join).to include("game_tray-vase")
      expect(reply.body).to include("game_tray-vase")
    end

    it "says plainly that it found nothing rather than implying it ran" do
      client = run([
        { tool_calls: [{ name: :print_history, arguments: { "query" => "nothing like this" } }] },
        { text: "No print on record for that one." },
      ])

      output = output_of(client)
      expect(output["prints"]).to be_empty
      expect(output["note"]).to include("that IS the outcome")
    end

    # The results were the whole point; nothing about a lookup belongs in a
    # checklist or an activity chip, and running it twice would double the query.
    it "leaves no proposal behind for ProposalBuilder to run again" do
      print!("game_tray-vase")
      allow(Buddy::ProposalBuilder).to receive(:create).and_call_original

      run([
        { tool_calls: [{ name: :print_history, arguments: { "query" => "game tray" } }] },
        { text: "Found it." },
      ])

      expect(Buddy::ProposalBuilder).not_to have_received(:create)
      expect(convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'")).to be_empty
    end

    # It answered the model in this turn; a second copy of the same reply,
    # arriving as a push, is what the relay used to produce.
    it "starts no second turn of its own" do
      allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
      print!("game_tray-vase")

      run([
        { tool_calls: [{ name: :print_history, arguments: { "query" => "game tray" } }] },
        { text: "Found it." },
      ])

      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
      expect(convo.byte_messages.where(direction: :inbound).count).to eq(1)
    end
  end

  # A turn can spend several rounds on tools before a word of the reply exists,
  # and all of it used to sit behind one "…". These lines go in its place.
  describe "saying what it's doing while it does it" do
    def broadcasts
      captured = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_user, payload| captured << payload }
      yield
      captured.filter_map { |p| p.dig(:data, :message, :metadata, "steps") }
    end

    it "pushes a line for each tool call, in the order they happen" do
      steps = broadcasts {
        run([
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
          { tool_calls: [{ name: :set_timer, arguments: { "minutes" => 5 } }] },
          { text: "Timer's going." },
        ])
      }

      expect(steps.last).to eq(["Going through your chores", "Starting the timer"])
    end

    # get_context fronts two dozen unrelated sections, so its own name says
    # nothing useful. Prod showed "Checking your day" while a doorbell watch was
    # being set up, which touches nothing about the day.
    it "names what it's actually looking up rather than the tool" do
      steps = broadcasts {
        run([
          { tool_calls: [{ name: :get_context, arguments: { "sections" => %w[jil_triggers jil_functions] } }] },
          { text: "Set." },
        ])
      }

      expect(steps.last).to eq(["Looking through your tools"])
    end

    it "falls back to something neutral when the sections are unrecognised" do
      expect(Buddy::Progress.phrase_for(:get_context, { "sections" => ["nonsense"] })).to eq("Looking things up")
      expect(Buddy::Progress.phrase_for(:get_context, nil)).to eq("Looking things up")
    end

    # The line has to be up BEFORE the tool runs, or the slowest part of the
    # turn is exactly the part that looks like nothing is happening.
    it "announces a step before running it, not after" do
      user.tasks.create!(
        name: "Print Again", listener: 'function("File" TAB String(""))::String',
        code: "a = String.new(\"ok\")::String", buddy_enabled: true
      )
      ran = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_u, p|
        ran << [:said, p.dig(:data, :message, :metadata, "steps")&.last]
      }
      allow(Buddy::Reprint).to receive(:call) {
        ran << [:did, "print"]
        { file: "x", task: "Print Again", outcome: :started, printer_said: "ok" }
      }

      run([
        { tool_calls: [{ name: :print_again, arguments: { "file" => "x" } }] },
        { text: "Printing." },
      ])

      expect(ran).to include([:said, "Asking the printer"])
      expect(ran.index([:said, "Asking the printer"])).to be < ran.index([:did, "print"])
    end

    it "doesn't stutter when the model repeats itself" do
      steps = broadcasts {
        run([
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["lists"] } }] },
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["lists"] } }] },
          { text: "Here." },
        ])
      }

      expect(steps.last).to eq(["Checking your lists"])
    end

    # They describe a turn in flight and mean nothing once it lands, so the row
    # never holds them and the finished reply is just the reply.
    it "leaves nothing behind on the message" do
      run([
        { tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
        { text: "All good." },
      ])

      expect(reply.metadata).not_to have_key("steps")
      expect(reply.body).to eq("All good.")
    end

    it "falls back to the tool's own name when it has no phrase of its own" do
      expect(Buddy::Progress.phrase_for(:some_new_tool)).to eq("Some new tool")
    end

    # set_mood fires on most turns. A line reading "Set mood" every time is the
    # noise this whole thing exists to replace.
    it "says nothing for the housekeeping it does alongside the real work" do
      steps = broadcasts {
        run([
          { tool_calls: [{ name: :set_mood, arguments: { "expression" => "happy" } }] },
          { tool_calls: [{ name: :get_context, arguments: { "sections" => ["lists"] } }] },
          { text: "Here." },
        ])
      }

      expect(steps.last).to eq(["Checking your lists"])
    end
  end

  describe "resolving the call before the model speaks" do
    it "hands back the resolved summary when the tool lines up" do
      ActionEvent.create!(user: user, name: "Dust shelves", timestamp: Time.current)
      client = run([
        { tool_calls: [{ name: :edit_event, arguments: { "event" => "Dust shelves", "notes" => "hallway" } }] },
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
      logged = ActionEvent.create!(user: user, name: "Untouched", timestamp: Time.current)

      run([
        { tool_calls: [{ name: :edit_event, arguments: { "event" => "Untouched", "name" => "Renamed" } }] },
        { text: "Tap when you're ready." },
      ])

      expect(logged.reload.name).to eq("Untouched")
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
        metadata: { "kind" => "buddy_trigger", "hidden" => true, "source" => "watch" }
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
