require "rails_helper"

RSpec.describe "Buddy commands that named a time" do
  # A device command that names a time must not run now: a sound played early
  # is physical, so this is a gate rather than a prompt rule.
  describe "a command that named a time" do
    let(:user) { User.me }
    # A real function task, so `call_jil_function`'s confirm resolves and the tool
    # would genuinely run. Without one the call fails on its own and the gate is
    # never the reason nothing happened.
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
      allow(Buddy::ProposalBuilder).to receive(:create) { |markers:, **|
        @markers = markers
        { action: nil, auto_ran: true }
      }
      convo.update_columns(buddy_theme: "byte", buddy_expression: "happy")
    end

    # What reached ProposalBuilder, in order: [tool, payload] pairs.
    def markers
      Array(@markers).map { |m| [m[:tool_name].to_sym, m[:payload].transform_keys(&:to_s)] }
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

    # A call held for later is told so, in place of running.
    def held(client)
      outputs(client).select { |o| %w[queued held covered].include?(o["status"]) }
    end

    def ran?(client)
      held(client).empty?
    end

    def play_call(call_id: "c1")
      {
        name:      :call_jil_function,
        call_id:   call_id,
        arguments: { "name" => "Whisper Sound", "sound" => "nap" },
      }
    end

    def schedule_call(at: 3.hours.from_now)
      {
        name:      :schedule_trigger,
        call_id:   "s1",
        arguments: { "scope" => "whisper-nap-sound", "at" => at.iso8601 },
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

    describe "reading the request" do
      def deferred?(text)
        Buddy::GPT::Turn::COMMAND_REQUEST_RX.match?(text) &&
          Buddy::GPT::Turn::DEFERRED_COMMAND_RX.match?(text)
      end

      it "catches a command with a time on it" do
        [
          "Play Whisper Nap sound at 11.",
          "Play the nap sound at 11pm",
          "turn the lights off at 10:30",
          "start the printer in 20 minutes",
          "run my wind-down tonight",
          "close the blinds at noon",
          "turn the fan on before bed",
          "play the wake sound when I get up",
        ].each { |text| expect(deferred?(text)).to be(true), text }
      end

      # A false positive here BLOCKS something they asked for, so the numbers that
      # aren't clocks matter more than usual. Both halves are required: a time
      # with no order in front of it is talking.
      it "leaves numbers that aren't times, immediate commands, and mere mentions alone" do
        [
          "set the thermostat at 72",
          "set the lights at 50%",
          "set the brightness at 40 percent",
          "set the heat at 68 degrees",
          "Play the nap sound on Whisper",
          "turn the kitchen lights off",
          "run my wind-down",
          "I'm heading out at 11",
          "is the dog asleep at noon usually?",
        ].each { |text| expect(deferred?(text)).to be(false), text }
      end
    end

    describe "the gate" do
      # `call_jil_function` is `answers: true` + `acts: true`, so it runs INSIDE
      # resolve_call rather than going through ProposalBuilder - which is why the
      # check sits in tool_output, ahead of it. Held there, it reaches
      # ProposalBuilder at the end of the turn on the scheduler built for it.
      it "puts it on the clock for the time they said instead of running it", :aggregate_failures do
        client = run(
          [{ tool_calls: [play_call] }, { text: "I'll play the nap sound at 11." }],
          text: "Play Whisper Nap sound at 11am.",
        )

        expect(ran?(client)).to be(false)
        expect(held(client).first["status"]).to eq("queued")
        expect(markers.map(&:first)).to eq([:schedule_function])
        expect(markers.first.last).to include("name" => "Whisper Sound", "sound" => "nap")
        expect(Time.zone.parse(markers.first.last["at"]).hour).to eq(11)
      end

      # There is no round budget to run out of here, because the gate isn't a nudge.
      it "holds a repeat of the same call as the one thing" do
        client = run(
          [
            { tool_calls: [play_call] },
            { tool_calls: [play_call(call_id: "c2")] },
            { text: "At 11." },
          ],
          text: "Play Whisper Nap sound at 11.",
        )

        expect(held(client).length).to eq(2)
        expect(markers.map(&:first)).to eq([:schedule_function])
      end

      # "Do this now and that at 11" is a real sentence: once something is
      # genuinely on the clock, the model has understood the time.
      it "lets a scheduling call, a call after one, and an ordinary immediate command through" do
        [
          [[schedule_call], "Play Whisper Nap sound at 11."],
          [[schedule_call, play_call], "Play Whisper Nap sound at 11."],
          [[schedule_call(at: 2.minutes.from_now), play_call], "Play the whisper wake sound in 2 minutes"],
          [[play_call], "Play the nap sound on Whisper"],
        ].each { |calls, text|
          client = run([{ tool_calls: calls }, { text: "Done." }], text: text)
          expect(ran?(client)).to be(true), "#{calls.pluck(:name)} on #{text.inspect}"
        }
      end

      # The model scheduling the thing AND doing it is the thing done twice.
      it "doesn't run it beside a schedule for the same function" do
        scheduled = {
          name:      :schedule_function,
          call_id:   "s1",
          arguments: { "name" => "Whisper Sound", "sound" => "nap", "at" => 2.minutes.from_now.iso8601 },
        }

        [[scheduled, play_call], [play_call, scheduled]].each { |calls|
          client = run([{ tool_calls: calls }, { text: "In two minutes." }], text: "Play the whisper wake sound in 2 minutes")

          expect(held(client).pluck("status")).to eq(["covered"]), calls.pluck(:name).inspect
          expect(markers.map(&:first)).to eq([:schedule_function])
        }
      end

      # Whichever order they come in, and whichever round, the function ends up
      # BEHIND the wait - never run now beside it.
      it "queues it behind a wait, in either order or a later round" do
        [
          [{ tool_calls: [play_call, wait_call] }],
          [{ tool_calls: [wait_call, play_call] }],
          [{ tool_calls: [wait_call] }, { tool_calls: [play_call] }],
        ].each { |rounds|
          client = run(rounds + [{ text: "Two minutes." }], text: "Play the whisper wake sound in 2 minutes")

          expect(ran?(client)).to be(false), rounds.inspect
          expect(markers.map(&:first)).to eq(%i[set_timer call_jil_function]), rounds.inspect
        }
      end

      # A plain countdown beside it was the model's way of saying "later". The
      # function goes on the clock, and the countdown doesn't ring over it.
      it "clocks it beside a bare countdown, and drops the countdown" do
        bare = wait_call(id: "t2").merge(arguments: { "seconds" => 120 })
        client = run([{ tool_calls: [play_call, bare] }, { text: "Two minutes." }], text: "Play the whisper wake sound in 2 minutes")

        expect(ran?(client)).to be(false)
        expect(markers.map(&:first)).to eq([:schedule_function])
      end

      # The time came from a shorthand taught earlier, so the words name none,
      # and the wait beside it is the only sign the request is for later.
      it "queues it behind a wait when the words name no time" do
        [
          [{ tool_calls: [play_call, wait_call] }],
          [{ tool_calls: [wait_call, play_call] }],
          [{ tool_calls: [wait_call] }, { tool_calls: [play_call] }],
        ].each { |rounds|
          client = run(rounds + [{ text: "Thirty minutes." }], text: "Sleep timer 30")

          expect(ran?(client)).to be(false), rounds.inspect
          expect(markers.map(&:first)).to eq(%i[set_timer call_jil_function]), rounds.inspect
        }
      end

      # A wait on its own, labelled for the thing and holding nothing: the thing
      # is asked for once more, before the wait has started, and rides it.
      it "asks for the missing call when a wait holds nothing, and queues it behind the wait", :aggregate_failures do
        client = run(
          [
            { tool_calls: [wait_call] },
            { text: "Set, the TV goes off in two minutes." },
            { tool_calls: [play_call(call_id: "c2")] },
            { text: "In two minutes." },
          ],
          text: "Turn off the tv in 2 minutes",
        )

        nudges = client.calls.flat_map(&:input).select { |i| i[:role] == :developer }.pluck(:content)
        expect(nudges).to include(Buddy::GPT::Turn::EMPTY_WAIT_NUDGE)
        expect(ran?(client)).to be(false)
        expect(markers.map(&:first)).to eq(%i[set_timer call_jil_function])
      end

      # A wait with something actually behind it is left to do its job.
      it "doesn't nudge a wait that holds something" do
        client = run([{ tool_calls: [wait_call, play_call] }, { text: "Two minutes." }], text: "Turn off the tv in 2 minutes")

        nudges = client.calls.flat_map(&:input).select { |i| i[:role] == :developer }.pluck(:content)
        expect(nudges).not_to include(Buddy::GPT::Turn::EMPTY_WAIT_NUDGE)
      end

      # One call, with the time on it: nothing to put in the wrong order.
      it "puts a call carrying its own run_in_minutes on the clock" do
        timed = play_call.merge(arguments: play_call[:arguments].merge("run_in_minutes" => 30))
        client = run([{ tool_calls: [timed] }, { text: "In half an hour." }], text: "Sleep timer 30")

        expect(ran?(client)).to be(false)
        expect(markers.map(&:first)).to eq([:schedule_function])
        expect(markers.first.last).not_to have_key("run_in_minutes")
        expect(Time.find_zone(user.timezone).parse(markers.first.last["at"])).to be_within(1.minute).of(30.minutes.from_now)
      end

      # A list add has a scheduler of its own, so a far-off one waits on that
      # rather than on a countdown chip sitting in the window for hours.
      it "puts a far-off list add on the list scheduler" do
        create(:list, user: user, name: "Groceries")
        add = {
          name:      :add_list_item,
          call_id:   "a1",
          arguments: { "list" => "Groceries", "item" => "Batteries", "run_in_minutes" => 188 },
        }
        run([{ tool_calls: [add] }, { text: "Later on." }], text: "Add batteries to the groceries list in 188 minutes")

        expect(markers.map(&:first)).to eq([:schedule_list_items])
        expect(markers.first.last).to include("list" => "Groceries", "items" => "Batteries")
        expect(Time.find_zone(user.timezone).parse(markers.first.last["at"])).to be_within(1.minute).of(188.minutes.from_now)
      end

      # Both halves carry the time, and a wait for that same moment rides along.
      # The calls go on the scheduler; the wait would only sit in the window
      # for hours holding nothing, so it goes.
      it "drops a wait that only restates the time the calls already carry" do
        wait  = { name: :set_timer, call_id: "t1", arguments: { "seconds" => 36_000, "then_continue" => true } }
        timed = play_call(call_id: "c2").merge(arguments: play_call[:arguments].merge("run_in_minutes" => 600))
        run([{ tool_calls: [wait, timed] }, { text: "Tonight." }], text: "play the Whisper nap sound in 10 hours")

        expect(markers.map(&:first)).to eq([:schedule_function])
      end

      # A time it couldn't read is still a time: held, never run.
      it "never runs a call whose run_at it couldn't read" do
        timed = play_call.merge(arguments: play_call[:arguments].merge("run_at" => "whenever"))
        client = run([{ tool_calls: [timed] }, { text: "Later." }], text: "Play the nap sound later")

        expect(ran?(client)).to be(false)
        expect(markers).to be_empty
      end

      it "reads a verbless order and a spelled-out delay" do
        ["TV off in 30", "Play the whisper wake sound in thirty minutes"].each { |text|
          client = run([{ tool_calls: [play_call] }, { text: "Will do." }], text: text)

          expect(ran?(client)).to be(false), text
          expect(markers.map(&:first)).to eq([:schedule_function]), text
        }
      end

      # A wait DOES defer a write: that reaches ProposalBuilder, which queues the
      # write behind it.
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

      it "counts only a scheduler that carries the thing itself as putting it on the clock" do
        expect(Buddy::GPT::Turn.puts_on_clock?(:set_timer, { "then_continue" => true })).to be(false)
        expect(Buddy::GPT::Turn.puts_on_clock?(:set_timer, { "seconds" => 120 })).to be(false)
        %i[schedule_reminder schedule_trigger schedule_function alarm remind_when].each do |name|
          expect(Buddy::GPT::Turn.puts_on_clock?(name, {})).to be(true), "expected #{name} to count"
        end

        expect(Buddy::GPT::Turn.queues_rest?(:set_timer, { "then_continue" => true })).to be(true)
        expect(Buddy::GPT::Turn.queues_rest?(:set_timer, { "seconds" => 120 })).to be(false)
        expect(Buddy::GPT::Turn.queues_rest?(:schedule_reminder, {})).to be(false)
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

  # Consecutive commands: "do X and then tell them" has to happen in that order,
  # even when X waits on a checkbox and the message would otherwise fire on
  # arrival.
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

    # A checkbox first, a partner message after it. An event edit is the gate
    # because it is still level 3; any level-3 tool reproduces the ordering.
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

    it "holds the partner message, reported queued, until the checkbox is tapped, then sends it once", :aggregate_failures do
      message, client = move_then_tell
      action = action_for(message)

      outputs = client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }
      expect(JSON.parse(outputs.find { |o| o[:call_id] == "c2" }[:output])["status"]).to eq("queued")
      expect(action.buttons.length).to eq(1)
      expect(relays).to be_empty

      2.times { Buddy::ProposalExecutor.perform(action.id, [1]) }

      expect(relays.count).to eq(1)
      expect(relays.first.body).to include("Costco Run")
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

  # The gate that holds an immediate tool back when the request said WHEN,
  # applied to list writes as well as device verbs.
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

    # A bare timer defers nothing and looks exactly like an ordinary countdown,
    # so ProposalBuilder can't see this shape and the gate is the only thing
    # between the item and the list.
    it "holds back a write with a time on it that was answered with a bare countdown, and adds it when the time comes", :aggregate_failures do
      client = ask("Add \"something\" to my todo list in 2 minutes", [add_item, timer(120)])

      expect(items).to be_empty
      expect(output_for(client, "c1")["status"]).to eq("queued")
      # The plain countdown is gone, and the one wait holding the item is ours.
      expect(user.timers.count).to eq(1)
      gate = ByteAction.find_by(user_id: user.id, tool_name: Buddy::ProposalBuilder::TIMER_GATE)

      Buddy::ProposalBuilder.resume_after!(Timer.find(gate.tool_input["timer_id"]))

      expect(items.pluck(:name)).to eq(["something"])
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
    # asks for something NOW; the round is read as a whole, whichever call came first.
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

    # The whole path, nothing stubbed but the task itself: the function sent
    # BEFORE its wait does not run, and runs exactly once when the wait is up.
    it "runs a function sent ahead of its wait when the wait is up, and not before" do
      task = Task.create!(
        user: user, name: "HASS TV", listener: "function(\"State\")",
        code: "", enabled: true, buddy_enabled: true
      )
      allow(Jil::Executor).to receive(:call)

      ask("Sleep timer 30", [
        { name: :call_jil_function, call_id: "c1", arguments: { "name" => task.name, "args" => { "state" => "off" } } },
        timer(1800, then_continue: true),
      ])

      expect(Jil::Executor).not_to have_received(:call)
      gate = ByteAction.find_by(user_id: user.id, tool_name: Buddy::ProposalBuilder::TIMER_GATE)

      Buddy::ProposalBuilder.resume_after!(Timer.find(gate.tool_input["timer_id"]))

      expect(Jil::Executor).to have_received(:call).once
    end

    it "still holds back a device command that named a time" do
      task = Task.create!(
        user: user, name: "Nap Sound", listener: "function(\"Nap\")",
        code: "", enabled: true, buddy_enabled: true
      )
      allow(Jil::Executor).to receive(:call)

      client = ask("Play the nap sound at 11am", [
        { name: :call_jil_function, call_id: "c1", arguments: { "name" => task.name, "args" => {} } },
      ])

      expect(Jil::Executor).not_to have_received(:call)
      expect(output_for(client, "c1")["status"]).to eq("queued")
      reminder = BuddyReminder.where(user: user).last
      expect(reminder.action).to include("tool" => "run_jil_task", "payload" => include("name" => "Nap Sound"))
      expect(reminder.fire_at.in_time_zone(user.timezone).hour).to eq(11)
    end
  end

  # "Do X in two minutes" must not do X now. The trailing time phrase reads to
  # the model as a second thing to do, so it emits the wait after the action.
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
    # the example.
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

    it "parks an action emitted BEFORE its wait on the countdown, and adds it when the timer is up" do
      ask("Add \"something\" to my todo list in 2 minutes", [add_item, wait_for(120)])

      expect(items).to be_empty
      expect(gate).to be_present
      expect(gate.tool_input["deferred"]).to be_present

      Buddy::ProposalBuilder.resume_after!(Timer.find(gate.tool_input["timer_id"]))

      expect(items.pluck(:name)).to eq(["something"])
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
