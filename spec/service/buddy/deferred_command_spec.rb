require "rails_helper"

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
RSpec.describe "Buddy commands that named a time" do
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
        :add_list_item, :remove_list_item
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
