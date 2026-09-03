require "rails_helper"

RSpec.describe "Buddy commands that named a time" do
  # Prod 3562, 10:44 AM: "Play Whisper Nap sound at 11."
  #
  # Buddy replied "Playing the nap sound on Whisper." and called
  # `call_jil_function` immediately — the receipt chip landed at 10:45. The sound
  # went off in the room sixteen minutes early, next to a sleeping dog.
  #
  # `message_partner` carries a whole section on this ("A DELAY IS IN THE
  # INSTRUCTION, NEVER IN THE NOTE") because the same thing happened with a relay.
  # Prose didn't generalize, and it wouldn't: the tool that acts NOW is right
  # there, its description says nothing about time, and every example in it is
  # immediate. A relay sent early is embarrassing; a sound played early is
  # physical, so this one is a gate rather than a rule.
  describe "a command that named a time" do
    let(:user) { User.me }
    # A real function task, so `call_jil_function`'s confirm resolves and the tool
    # would genuinely run. Without one the call fails on its own and the gate is
    # never the reason nothing happened — which is how the first draft of this
    # spec passed while proving nothing.
    let!(:whisper) {
      Task.create!(
        user: user, name: "Whisper Sound", buddy_enabled: true,
        listener: 'function("Sound" TAB String)::String',
        description: "Play a sound cue on Whisper's timer display."
      )
    }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(Buddy::ProposalBuilder).to receive(:create).and_return(action: nil, auto_ran: true)
      convo.update_columns(buddy_theme: "byte", buddy_expression: "happy")
    end

    def user_says(text)
      convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: text)
    end

    def run(rounds, text:)
      client = FakeBuddyClient.new(rounds)
      Buddy::GPT::Turn.run!(user_says(text), client: client)
      client
    end

    # What came BACK to the model for each call it made. A held-back call is
    # reported the same way any other refusal is, so this is where the gate shows.
    #
    # Deduped by call_id: every round's input carries the whole history, so the
    # first round's outputs appear again in each round after it.
    def outputs(client)
      rows = client.calls.flat_map { |c| c.input.select { |i| i[:type] == :function_call_output } }
      rows = rows.uniq { |i| i[:call_id] }
      rows.map { |i| JSON.parse(i[:output]) }
    end

    def play_call
      {
        name:      :call_jil_function,
        call_id:   "c1",
        arguments: { "name" => "Whisper Sound", "sound" => "nap" },
      }
    end

    # The wait the model reaches for when it has read "in 2 minutes" and decided
    # the delay is something it can hold the rest of the reply in.
    def wait_call(id: "t1")
      {
        name:      :set_timer,
        call_id:   id,
        arguments: { "seconds" => 120, "label" => "Whisper wake sound", "then_continue" => true },
      }
    end

    def ran?(client)
      outputs(client).none? { |o| o["error"].to_s.include?("they said when") }
    end

    describe "reading the request" do
      def deferred?(text)
        Buddy::GPT::Turn::COMMAND_REQUEST_RX.match?(text) &&
          Buddy::GPT::Turn::DEFERRED_COMMAND_RX.match?(text)
      end

      it "catches the one from prod" do
        expect(deferred?("Play Whisper Nap sound at 11.")).to be(true)
      end

      it "catches the other ways of saying when" do
        expect(deferred?("Play the nap sound at 11pm")).to be(true)
        expect(deferred?("turn the lights off at 10:30")).to be(true)
        expect(deferred?("start the printer in 20 minutes")).to be(true)
        expect(deferred?("run my wind-down tonight")).to be(true)
        expect(deferred?("close the blinds at noon")).to be(true)
        expect(deferred?("turn the fan on before bed")).to be(true)
        expect(deferred?("play the wake sound when I get up")).to be(true)
      end

      # A false positive here BLOCKS something they asked for, so the numbers that
      # aren't clocks matter more than usual.
      it "leaves a number that isn't a time alone" do
        expect(deferred?("set the thermostat at 72")).to be(false)
        expect(deferred?("set the lights at 50%")).to be(false)
        expect(deferred?("set the brightness at 40 percent")).to be(false)
        expect(deferred?("set the heat at 68 degrees")).to be(false)
      end

      it "leaves an ordinary immediate command alone" do
        expect(deferred?("Play the nap sound on Whisper")).to be(false)
        expect(deferred?("turn the kitchen lights off")).to be(false)
        expect(deferred?("run my wind-down")).to be(false)
      end

      # Both halves are required. A time with no order in front of it is talking.
      it "leaves a sentence that only mentions a time alone" do
        expect(deferred?("I'm heading out at 11")).to be(false)
        expect(deferred?("is the dog asleep at noon usually?")).to be(false)
      end
    end

    describe "the gate" do
      # The whole thing. `call_jil_function` is `answers: true` + `acts: true`, so
      # it runs INSIDE resolve_call rather than going through ProposalBuilder —
      # which is why the check sits in tool_output, ahead of it. Anywhere later is
      # after the sound has played.
      it "does not run the function the person asked for at 11" do
        client = run(
          [{ tool_calls: [play_call] }, { text: "I'll get that going at 11." }],
          text: "Play Whisper Nap sound at 11.",
        )

        expect(ran?(client)).to be(false)
      end

      it "tells the model why, and what to reach for instead" do
        client = run(
          [{ tool_calls: [play_call] }, { text: "Set for 11." }],
          text: "Play Whisper Nap sound at 11.",
        )

        held = outputs(client).find { |o| o["error"].to_s.include?("they said when") }
        expect(held["status"]).to eq("failed")
        expect(held["note"]).to include("schedule_trigger", "schedule_reminder", "alarm")
        expect(held["note"]).to include("never say it's scheduled when it isn't")
      end

      # Reported as `failed`, which is what arms the retraction. A reply that says
      # the sound is playing over a call that was held back is the same lie as one
      # over a call that never happened.
      it "retracts a reply that says it happened anyway" do
        run(
          [{ tool_calls: [play_call] }, { text: "Playing the nap sound on Whisper." }],
          text: "Play Whisper Nap sound at 11.",
        )

        reply = convo.byte_messages.where(direction: :inbound).order(:created_at).last
        expect(reply.metadata["retracted_claim"]).to be(true)
      end

      # A model that keeps asking gets the same answer. There is no round budget
      # to run out of here, because the gate isn't a nudge.
      it "still holds it back when a later round makes the same call" do
        client = run(
          [
            { tool_calls: [play_call] },
            { tool_calls: [play_call.merge(call_id: "c2")] },
            { text: "Playing it now." },
          ],
          text: "Play Whisper Nap sound at 11.",
        )

        expect(ran?(client)).to be(false)
        expect(outputs(client).count { |o| o["error"].to_s.include?("they said when") }).to eq(2)
      end

      it "lets a scheduling call through untouched" do
        client = run(
          [
            { tool_calls: [{
              name:      :schedule_trigger,
              call_id:   "s1",
              arguments: {
                "scope" => "whisper-nap-sound",
                "at"    => 3.hours.from_now.iso8601,
              },
            }] },
            { text: "That'll go off at 11." },
          ],
          text: "Play Whisper Nap sound at 11.",
        )

        expect(ran?(client)).to be(true)
      end

      # "Do this now and that at 11" is a real sentence. Once something is
      # genuinely on the clock, the model has understood the time.
      it "allows an immediate call after something was actually scheduled" do
        client = run(
          [
            { tool_calls: [
              {
                name:      :schedule_trigger,
                call_id:   "s1",
                arguments: {
                  "scope" => "whisper-nap-sound",
                  "at"    => 3.hours.from_now.iso8601,
                },
              },
              play_call,
  ] },
            { text: "Both sorted." },
          ],
          text: "Play Whisper Nap sound at 11.",
        )

        expect(ran?(client)).to be(true)
      end

      it "leaves an ordinary immediate command alone" do
        client = run(
          [{ tool_calls: [play_call] }, { text: "Playing it." }],
          text: "Play the nap sound on Whisper",
        )

        expect(ran?(client)).to be(true)
      end

      # Prod 4081, "Play the whisper wake sound in 2 minutes".
      #
      # The model emitted the function AND a two-minute `then_continue` wait in
      # one round. The round-level read saw the wait, took the time as understood
      # and stood the gate down — so Whisper Sound fired at 21:04:35 and the wait
      # it was supposedly riding was created a second later, holding an empty
      # queue (timer 78, metadata `{}`). The sound played in the room two minutes
      # early, which is the entire thing this gate exists to stop.
      #
      # A wait can hold a step that goes through ProposalBuilder. It cannot hold
      # one that has already run by the time a proposal queue exists, and
      # `call_jil_function` is `answers: true` — it settles inside resolve_call.
      describe "a wait is not a schedule" do
        it "holds the function back when the wait rides along with it" do
          client = run(
            [
              { tool_calls: [play_call, wait_call] },
              { text: "That'll play in two minutes." },
            ],
            text: "Play the whisper wake sound in 2 minutes",
          )

          expect(ran?(client)).to be(false)
        end

        # Which one the model emits first is arbitrary, and running early is just
        # as wrong when the wait was named first.
        it "holds it back with the wait in front" do
          client = run(
            [
              { tool_calls: [wait_call, play_call] },
              { text: "Two minutes." },
            ],
            text: "Play the whisper wake sound in 2 minutes",
          )

          expect(ran?(client)).to be(false)
        end

        it "holds it back when the wait came a round earlier" do
          client = run(
            [
              { tool_calls: [wait_call] },
              { tool_calls: [play_call] },
              { text: "Two minutes." },
            ],
            text: "Play the whisper wake sound in 2 minutes",
          )

          expect(ran?(client)).to be(false)
        end

        # A bare countdown never counted, and it still doesn't.
        it "holds it back behind a plain countdown too" do
          client = run(
            [
              { tool_calls: [play_call, wait_call(id: "t2").merge(arguments: { "seconds" => 120 })] },
              { text: "Two minutes." },
            ],
            text: "Play the whisper wake sound in 2 minutes",
          )

          expect(ran?(client)).to be(false)
        end

        # The other half. A wait DOES defer a write: that reaches
        # ProposalBuilder, `hoist_dangling_wait` rotates the wait to the front and
        # the write queues behind it. Holding those back would undo the fix for
        # prod 3897.
        it "still lets a wait cover something that can actually be queued" do
          client = run(
            [
              { tool_calls: [
                { name: :add_list_item, call_id: "a1", arguments: { "list" => "Groceries", "item" => "milk" } },
                wait_call,
              ] },
              { text: "Two minutes." },
            ],
            text: "Add milk to my list in 2 minutes",
          )

          expect(ran?(client)).to be(true)
        end

        # A real scheduler takes the payload and the time together, so there's
        # nothing left for this turn to do early. That one covers everything.
        it "still lets a real schedule cover the function" do
          client = run(
            [
              { tool_calls: [
                { name: :schedule_trigger, call_id: "s1", arguments: { "scope" => "whisper-wake", "at" => 2.minutes.from_now.iso8601 } },
                play_call,
              ] },
              { text: "Set." },
            ],
            text: "Play the whisper wake sound in 2 minutes",
          )

          expect(ran?(client)).to be(true)
        end
      end

      describe "what counts as putting it on the clock" do
        it "does not count a wait" do
          expect(Buddy::GPT::Turn.puts_on_clock?(:set_timer, { "then_continue" => true })).to be(false)
          expect(Buddy::GPT::Turn.puts_on_clock?(:set_timer, { "seconds" => 120 })).to be(false)
        end

        it "counts a scheduler that carries the thing itself" do
          %i[schedule_reminder schedule_trigger schedule_function alarm remind_when].each do |name|
            expect(Buddy::GPT::Turn.puts_on_clock?(name, {})).to be(true), "expected #{name} to count"
          end
        end

        it "reads a wait as a wait, and only when it carries the rest" do
          expect(Buddy::GPT::Turn.queues_rest?(:set_timer, { "then_continue" => true })).to be(true)
          expect(Buddy::GPT::Turn.queues_rest?(:set_timer, { "seconds" => 120 })).to be(false)
          expect(Buddy::GPT::Turn.queues_rest?(:schedule_reminder, {})).to be(false)
        end
      end

      # Both descriptions were telling the model to do the thing that broke. The
      # tool that acts on the spot said "set_timer with then_continue: true for a
      # delay"; set_timer said the same in reverse, with "play the nap sound in 2
      # minutes" as its worked example.
      describe "what the schema tells it" do
        it "stops offering a wait to a tool a wait can't hold" do
          %i[call_jil_function print_again].each do |name|
            schema = Buddy::Tools.function_schema(Buddy::Tools[name])
            expect(schema[:description]).to include("a wait CANNOT hold it")
            expect(schema[:description]).not_to include("set_timer with then_continue")
          end
        end

        it "still offers one to a tool that can be queued behind it" do
          schema = Buddy::Tools.function_schema(Buddy::Tools[:add_list_item])

          expect(schema[:description]).to include("set_timer with then_continue")
        end

        it "no longer teaches the wait with the sound that started this" do
          schema = Buddy::Tools.function_schema(Buddy::Tools[:set_timer])

          expect(schema[:description]).not_to include("play the nap sound in 2 minutes")
          expect(schema[:description]).to include("a wait CANNOT hold them")
        end
      end

      # Tools that carry their own sense of when are exactly the ones where "at 3"
      # is an argument, not a deferral. Backdating a water to 3pm is a legitimate
      # call on a sentence the regex matches.
      it "leaves tools that have their own time argument off the list" do
        %i[log_event complete_chore edit_chore schedule_reminder alarm].each do |name|
          expect(Buddy::Tools::IMMEDIATE_ACTION_TOOLS).not_to include(name)
        end
      end

      it "gates every tool that acts on the world with no notion of when" do
        expect(Buddy::Tools::IMMEDIATE_ACTION_TOOLS).to contain_exactly(
          :call_jil_function, :trigger_jil_task, :run_routine, :mac_command, :print_again,
          :add_list_item, :remove_list_item, :add_inventory_item, :remove_inventory_item
        )
      end

      # The list is read twice, and the second reader is the schema: being on it
      # is how a tool gets told about time at all, since none of their own
      # descriptions mention it.
      it "tells each gated tool that it acts the moment it's called" do
        Buddy::Tools::IMMEDIATE_ACTION_TOOLS.each do |name|
          schema = Buddy::Tools.function_schema(Buddy::Tools[name])
          expect(schema[:description]).to include("never part of what to do")
        end
      end

      it "does not put that on a tool that means later" do
        schema = Buddy::Tools.function_schema(Buddy::Tools[:schedule_reminder])

        expect(schema[:description]).not_to include("never part of what to do")
      end
    end

    # Nobody spoke, so there is no request to read a time out of.
    it "never fires on a self-initiated turn" do
      seed = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :pending,
        body: "Run the evening check at 11", metadata: { "kind" => "buddy_trigger", "hidden" => true }
      )
      client = FakeBuddyClient.new([{ tool_calls: [play_call] }, { text: "Done." }])
      Buddy::GPT::Turn.run!(seed, client: client)

      expect(ran?(client)).to be(true)
    end
  end

  # Consecutive commands: "do X and then tell them" has to happen in that order.
  #
  # Prod 1201 is the whole reason this exists. "Can you move it to the Ours agenda
  # and let Chelsea know?" produced add_agenda_item (level 3, a checkbox) and
  # message_partner (level 1, fires on arrival). ProposalBuilder split them purely
  # on level, so at 18:02:25 Chelsea was told the event had moved — and the
  # checkbox that actually moved it wasn't tapped until 18:02:47. Had it never
  # been tapped, she'd have been told about a move that never happened.
  describe "deferred actions" do
    let(:user)       { create(:user) }
    let(:partner)    { create(:user) }
    let(:her)        { partner.username } # first_name == username for factory users
    let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
    let!(:convo)     {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }
    let(:at) { Time.current.tomorrow.change(hour: 13) }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
      allow(Buddy::CompanionRelay).to receive(:deliver!)
      ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
      user.update!(chore_household_id: household.id)
      partner.update!(chore_household_id: household.id)
      convo.update_columns(buddy_theme: "byte")
    }

    def reply
      convo.byte_messages.where(direction: :inbound).order(:created_at).first
    end

    # The 1201 shape: a checkbox first, a partner message after it. The gate is an
    # event edit rather than the agenda add of the original report, because agenda
    # and chore writes have both since moved to level 2 and run on arrival — any
    # level-3 tool reproduces the ordering this is about.
    def move_then_tell
      ActionEvent.create!(user: user, name: "Costco Run", timestamp: Time.current)
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "fix the costco run and let Chelsea know")
      client  = FakeBuddyClient.new([
        {
          tool_calls: [
            { name: :edit_event, call_id: "c1", arguments: { "event" => "Costco Run", "notes" => "moved" } },
            { name: :message_partner, call_id: "c2", arguments: { "to" => her, "message" => "Costco Run's sorted." } },
          ],
        },
        { text: "Once you tap that, I'll let Chelsea know." },
      ])
      Buddy::GPT::Turn.run!(inbound, client: client)
      [reply, client]
    end

    def relays
      BuddyRelay.where(from_user_id: user.id)
    end

    def action_for(message)
      ByteAction.find_by(byte_message_id: message.id)
    end

    it "does not send the partner message while the checkbox is still waiting" do
      message, = move_then_tell

      expect(action_for(message).buttons.length).to eq(1)
      expect(relays).to be_empty
    end

    it "sends it once the checkbox is tapped" do
      message, = move_then_tell
      action   = action_for(message)

      Buddy::ProposalExecutor.perform(action.id, [1])

      expect(relays.count).to eq(1)
      expect(relays.first.body).to include("Costco Run")
    end

    it "runs it exactly once, even if the tap is replayed" do
      message, = move_then_tell
      action   = action_for(message)

      Buddy::ProposalExecutor.perform(action.id, [1])
      Buddy::ProposalExecutor.perform(action.id, [1])

      expect(relays.count).to eq(1)
    end

    it "never sends it when the thing it was announcing failed" do
      message, = move_then_tell
      action   = action_for(message)
      # The row resolves but blows up on execute — the move did not happen, so
      # neither should the announcement.
      allow(Buddy::Tools).to receive(:dispatch).and_return({ ok: false, error: "nope" })

      Buddy::ProposalExecutor.perform(action.id, [1])

      expect(relays).to be_empty
    end

    it "says what it held back, rather than going quiet about it" do
      message, = move_then_tell
      action   = action_for(message)
      allow(Buddy::Tools).to receive(:dispatch).and_return({ ok: false, error: "nope" })

      Buddy::ProposalExecutor.perform(action.id, [1])

      held = convo.byte_messages.where(direction: :inbound).order(:created_at).last
      expect(held.body).to include("Held off on")
      expect(held.body).to include("Message #{her}")
    end

    it "tells the model the follow-up is queued, not done" do
      _message, client = move_then_tell

      outputs = client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }
      queued  = JSON.parse(outputs.find { |o| o[:call_id] == "c2" }[:output])

      expect(queued["status"]).to eq("queued")
      expect(queued["note"]).to include("has NOT run")
    end

    it "leaves a level-1 call made BEFORE the checkbox firing immediately" do
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "tell Chelsea, and put Costco on the calendar")
      client  = FakeBuddyClient.new([
        {
          tool_calls: [
            { name: :message_partner, call_id: "c1", arguments: { "to" => her, "message" => "Heads up." } },
            { name: :add_agenda_item, call_id: "c2", arguments: { "title" => "Costco Run", "at" => at.iso8601 } },
          ],
        },
        { text: "Told her, and that one's ready to tap." },
      ])
      Buddy::GPT::Turn.run!(inbound, client: client)

      expect(relays.count).to eq(1)
    end

    it "leaves a turn with no checkbox at all completely alone" do
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "let Chelsea know I'm heading out")
      client  = FakeBuddyClient.new([
        { tool_calls: [{ name: :message_partner, call_id: "c1", arguments: { "to" => her, "message" => "Heading out." } }] },
        { text: "Told her." },
      ])
      Buddy::GPT::Turn.run!(inbound, client: client)

      expect(relays.count).to eq(1)
    end
  end

  # The gate that holds an immediate tool back when the request said WHEN.
  #
  # It has always existed for the device verbs (prod 3562, "Play Whisper Nap sound
  # at 11", which played it 16 minutes early next to a sleeping dog). Prod 3897
  # walked straight past it twice over: "Add "something" to my todo list in 2
  # minutes" opens with a verb the command regex doesn't know, and `add_list_item`
  # was not on the list of tools it guards.
  describe "the write gate" do
    let(:user)   { create(:user) }
    let!(:todo)  { create(:list, user: user, name: "Todo") }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      TimerFireWorker.clear
      convo.update_columns(buddy_theme: "byte")
    }

    def ask(body, calls)
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
      client  = FakeBuddyClient.new([{ tool_calls: calls }, { text: "Sorted." }])
      Buddy::GPT::Turn.run!(inbound, client: client)
      client
    end

    def add_item(item: "something", call_id: "c1")
      { name: :add_list_item, call_id: call_id, arguments: { "list" => "Todo", "item" => item } }
    end

    def timer(seconds, then_continue: false, call_id: "c2")
      args = { "seconds" => seconds }
      args["then_continue"] = true if then_continue
      { name: :set_timer, call_id: call_id, arguments: args }
    end

    def items
      ListItem.joins(:list).where(lists: { id: todo.id })
    end

    # What the model was told about the call it made.
    #
    # Across every call rather than the last one: a turn that ends with nothing
    # run gets a second attempt, and that attempt is built fresh from the
    # thread, so the outputs are not in its input. See Turn#start_over?.
    def output_for(client, call_id)
      outputs = client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }
      JSON.parse(outputs.find { |o| o[:call_id] == call_id }[:output])
    end

    # The 3897 shape with the flag left off: the write plus a plain countdown.
    # ProposalBuilder can't see this one — a bare timer defers nothing and looks
    # exactly like an ordinary countdown — so the gate is the only thing between
    # the item and the list.
    describe "a write with a time on it, answered with a bare countdown" do
      let!(:client) { ask("Add \"something\" to my todo list in 2 minutes", [add_item, timer(120)]) }

      it "does not add it" do
        expect(items).to be_empty
      end

      it "tells the model it did not run, and why" do
        held = output_for(client, "c1")

        expect(held["status"]).to eq("failed")
        expect(held["note"]).to include("says when to act")
      end
    end

    # The other half of the same sentence, and it must still work: no time named
    # means nothing to defer.
    it "adds it when no time was named" do
      ask("Add milk to my todo list", [add_item(item: "milk")])

      expect(items.pluck(:name)).to eq(["milk"])
    end

    # A WAIT is the model getting it right — it says the rest of the sequence
    # rides on the countdown — so the gate steps aside and ProposalBuilder takes
    # over. Without this the two fixes would fight, and the gate would refuse the
    # very shape it's trying to teach.
    it "stands aside for a wait that carries the rest of the sequence" do
      ask(
        "Add milk to my todo list in 2 minutes",
        [timer(120, then_continue: true, call_id: "c1"), add_item(item: "milk", call_id: "c2")],
      )

      expect(items).to be_empty
      expect(ByteAction.where(tool_name: Buddy::ProposalBuilder::TIMER_GATE)).to be_present
    end

    # "Remind me at 5 to call mom, and add milk to the list" names a time and then
    # asks for something NOW. Which call the model emits first is arbitrary, and
    # reading them one at a time meant the reminder only covered the milk when it
    # happened to come first.
    it "lets a write through when the round also scheduled something, whichever order" do
      ask("Add milk to my list, and remind me at 5 to call mom", [
        add_item(item: "milk", call_id: "c1"),
        {
          name:      :schedule_reminder,
          call_id:   "c2",
          arguments: { "text" => "Call mom", "at" => Time.current.change(hour: 17).iso8601 },
        },
      ])

      expect(items.pluck(:name)).to eq(["milk"])
    end

    # The device half of the gate is untouched by any of this — prod 3562 stays
    # caught.
    it "still holds back a device command that named a time" do
      task = Task.create!(
        user: user, name: "Nap Sound", listener: "function(\"Nap\")",
        code: "", enabled: true, buddy_enabled: true
      )
      allow(Jil::Executor).to receive(:call)

      client = ask("Play the nap sound at 11", [
        { name: :call_jil_function, call_id: "c1", arguments: { "name" => task.name, "args" => {} } },
      ])

      expect(Jil::Executor).not_to have_received(:call)
      expect(output_for(client, "c1")["status"]).to eq("failed")
    end
  end

  # "Do X in two minutes" must not do X now.
  #
  # Prod 3897: "Add "something" to my todo list in 2 minutes" came back as
  # add_list_item followed by set_timer(then_continue: true). ListItem 6397 was
  # created on the spot at 18:15:16, byte_action 561 stored an EMPTY deferred
  # queue, and timer 69 rang at 18:17 over a job already done. Reported as a very
  # common shape: the trailing time phrase reads to the model as a second thing to
  # do rather than as when to do the first, so it gets appended in the order it
  # was spoken.
  #
  # `then_continue` is the model's own claim that the rest rides on the wait, so a
  # wait with nothing behind it is a contradiction, and what it meant to hold is
  # whatever it emitted just before.
  describe "a wait with nothing after it" do
    let(:user)   { create(:user) }
    let!(:todo)  { create(:list, user: user, name: "Todo") }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }

    # The suite runs Sidekiq inline, so a countdown started here would fire during
    # the example — and every assertion about what's still WAITING would really be
    # an assertion about how fast the spec ran.
    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      TimerFireWorker.clear
      convo.update_columns(buddy_theme: "byte")
    }

    def ask(body, calls, reply: "Will do.")
      inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
      client  = FakeBuddyClient.new([{ tool_calls: calls }, { text: reply }])
      Buddy::GPT::Turn.run!(inbound, client: client)
      client
    end

    def add_item(call_id: "c1", item: "something")
      { name: :add_list_item, call_id: call_id, arguments: { "list" => "Todo", "item" => item } }
    end

    def wait_for(seconds, call_id: "c2", then_continue: true)
      args = { "seconds" => seconds }
      args["then_continue"] = true if then_continue
      { name: :set_timer, call_id: call_id, arguments: args }
    end

    def gate
      ByteAction.find_by(user_id: user.id, tool_name: Buddy::ProposalBuilder::TIMER_GATE)
    end

    def items
      ListItem.joins(:list).where(lists: { id: todo.id })
    end

    # The 3897 shape, exactly.
    describe "an action emitted BEFORE the wait it belongs behind" do
      before { ask("Add \"something\" to my todo list in 2 minutes", [add_item, wait_for(120)]) }

      it "does not add the item yet" do
        expect(items).to be_empty
      end

      it "parks the item on the countdown instead of leaving the queue empty" do
        expect(gate).to be_present
        expect(gate.tool_input["deferred"]).to be_present
      end

      it "adds it when the timer is up" do
        timer = Timer.find(gate.tool_input["timer_id"])

        Buddy::ProposalBuilder.resume_after!(timer)

        expect(items.pluck(:name)).to eq(["something"])
      end
    end

    # The flag is what makes the wait a wait. Without it there is nothing to
    # contradict, and "add milk and set a ten minute timer" is two ordinary
    # requests that both happen now.
    it "leaves a bare countdown alone" do
      ask(
        "Add milk to my todo list and set a 10 minute timer",
        [add_item(item: "milk"), wait_for(600, then_continue: false)],
      )

      expect(items.pluck(:name)).to eq(["milk"])
      expect(gate).to be_nil
    end

    # A real chain already puts its steps on the right side of the wait, and
    # rotating one would run it backwards. Each half stays where the model put it.
    it "leaves a wait that has a step after it alone" do
      ask(
        "Add milk now, then in a minute add eggs",
        [add_item(item: "milk"), wait_for(60), add_item(call_id: "c3", item: "eggs")],
      )

      expect(items.pluck(:name)).to eq(["milk"])

      Buddy::ProposalBuilder.resume_after!(Timer.find(gate.tool_input["timer_id"]))

      expect(items.pluck(:name)).to contain_exactly("milk", "eggs")
    end

    # Nothing came before it, so there is nothing it could have meant to hold —
    # and a lone wait is still an honest countdown.
    it "leaves a wait that is the only step alone" do
      ask("Give me two minutes", [wait_for(120, call_id: "c1")])

      expect(gate).to be_nil
    end
  end
end
