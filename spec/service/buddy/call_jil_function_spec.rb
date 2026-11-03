require "rails_helper"

# call_jil_function acts AND reports, inside the turn. The function runs while
# the model is still deciding what to say, and its return value goes back as the
# tool output, so the reply is written knowing the outcome.
RSpec.describe "call_jil_function tool" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  # A sensor reader whose whole point is what it returns.
  let!(:sensor_task) {
    Task.create!(
      user:          user,
      name:          "HASS Sensor State",
      listener:      'function("Sensor" TAB ["kennel" "laundry_gate" "doggy_door"]("doggy_door"))::String',
      code:          "// noop",
      enabled:       true,
      buddy_enabled: true,
      description:   "Checks a Home Assistant binary sensor, reporting open or closed",
    )
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  # The Jil executor itself is out of scope here; all this tool cares about is
  # the value coming back off `#result`.
  def stub_execution(result)
    allow_any_instance_of(Task).to receive(:execute)
      .and_return(instance_double(::Jil::Executor, result: result))
  end

  # The path a level-1 answering tool actually takes: resolved and executed
  # inside Turn, with the output handed straight back to the model.
  def run(payload)
    Buddy::GPT::Turn.resolve_call(
      Buddy::Tools[:call_jil_function],
      { name: "call_jil_function", arguments: payload, call_id: "c1" },
      user: user, conversation: convo,
    ).first
  end

  def chip
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
  end

  describe "the answer" do
    # The shape these functions really return.
    let(:real_output) { "laundry_gate is closed (raw state: off, last changed: 2026-07-30T02:14:14.188937+00:00)" }

    it "hands what the function returned back to the model in the same turn" do
      stub_execution(real_output)

      result = run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })

      expect(result[:status]).to eq(:answered)
      expect(result[:answer]).to include("laundry_gate is closed")
    end

    # The model reads a clock fine and moves one badly, so the conversion
    # happens before it ever sees the line (see Buddy::RawOutput).
    it "localizes a UTC stamp rather than asking the model to convert one" do
      stub_execution(real_output)

      result = travel_to(Time.utc(2026, 7, 31, 18, 0, 0)) {
        run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })
      }

      expect(result[:answer]).to include("8:14pm on Jul 29")
      expect(result[:answer]).not_to include("02:14:14")
      expect(result[:answer]).not_to include("+00:00")
    end

    it "relays a command's own report, and no answer at all when it returned only blanks" do
      stub_execution("The garage was already closed, so nothing was sent.")
      expect(run({ name: "HASS Sensor State", sensor: "kennel" })[:answer])
        .to eq("The garage was already closed, so nothing was sent.")

      stub_execution("   ")
      expect(run({ name: "HASS Sensor State", sensor: "kennel" })).not_to have_key(:answer)
    end
  end

  describe "the receipt chip" do
    it "files one for a command, carrying both the args and what came back" do
      stub_execution("ok")

      run({ name: "HASS Sensor State", sensor: "kennel" })

      expect(chip.body).to eq("Called **HASS Sensor State**")
      expect(chip.metadata["detail"]).to eq("sensor: kennel\nok")
      expect(chip.metadata["payload"]).to include("sensor" => "kennel")
    end

    # Buddy is about to speak the state itself, so a pill above it saying the
    # same thing is noise.
    it "skips one for a declared lookup" do
      stub_execution("kennel is closed")

      run({ name: "HASS Sensor State", sensor: "kennel", expect_result: true })

      expect(chip).to be_nil
    end

    it "still files one when the function returns nothing" do
      stub_execution(nil)

      run({ name: "HASS Sensor State", sensor: "kennel" })

      expect(chip.body).to include("HASS Sensor State")
    end
  end

  # Reading with a writer is the dangerous mis-selection: asked "are the blinds
  # open?", the model reached for the blinds ACTUATOR with action="position",
  # which moves them rather than reporting. Prompt wording alone didn't hold.
  describe "refusing to answer a question with a command function" do
    let!(:blinds) {
      Task.create!(
        user:          user,
        name:          "HASS Blinds",
        listener:      'function("Action" TAB ["open" "close" "stop" "position"]("open"))::String',
        code:          "// noop",
        enabled:       true,
        buddy_enabled: true,
        description:   "Opens, closes, stops, or sets the position of the living room blinds",
      )
    }

    it "fails the call rather than firing an actuator to satisfy a question" do
      allow_any_instance_of(Task).to receive(:execute).and_raise("should never run")

      result = run({ name: "HASS Blinds", action: "position", expect_result: true })

      expect(result[:status]).to eq("failed")
      expect(chip).to be_nil
    end

    it "still runs it normally as a command" do
      stub_execution("closed")

      run({ name: "HASS Blinds", action: "close" })

      expect(chip.body).to eq("Called **HASS Blinds**")
      expect(chip.metadata["detail"]).to include("action: close")
    end
  end

  describe "argument handling" do
    it "never forwards expect_result to the Jil function as a parameter" do
      captured = nil
      allow_any_instance_of(Task).to receive(:execute) { |_t, input, **_kw|
        captured = input
        instance_double(::Jil::Executor, result: "closed")
      }

      run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })

      expect(captured.keys).to contain_exactly("sensor", "params")
      expect(captured["params"]).to eq(["laundry_gate"])
    end

    # A task reading `Keyword.Item()` gets its args BY POSITION, so `params`
    # deciding the order decides what the task does. It used to be built from
    # the keys the caller happened to hand over, which is not the same thing.
    describe "the positional params array" do
      let!(:blinds) {
        Task.create!(
          user:          user,
          name:          "HASS Blinds",
          listener:      'function("Action" TAB ["open" "close" "stop" "position"]("open") BR ' \
                         '"Which" TAB ["all" "great_room" "stairs"]("great_room") BR "Position" TAB Numeric)::String',
          code:          "// noop",
          enabled:       true,
          buddy_enabled: true,
          description:   "Opens, closes, stops, or sets the position of the blinds",
        )
      }

      def captured_for(payload)
        captured = nil
        allow_any_instance_of(Task).to receive(:execute) { |_t, input, **_kw|
          captured = input
          instance_double(::Jil::Executor, result: "ok")
        }
        run(payload)
        captured
      end

      it "orders by the signature, not by key order, and still names every arg at the top level" do
        input = captured_for({ name: "HASS Blinds", which: "all", action: "close", position: 0 })

        expect(input["params"]).to eq(["close", "all", 0])
        expect(input).to include("action" => "close", "which" => "all", "position" => 0)
      end

      # Routine steps live in jsonb, and Postgres sorts object keys by length
      # then bytes, so a saved payload comes back in a different key order.
      it "survives the routine round trip that scrambled it" do
        routine = BuddyRoutine.create!(
          user:  user,
          name:  "lockdown",
          steps: [
            BuddyRoutine.step(
              :call_jil_function,
              { name: "HASS Blinds", action: "close", which: "all", position: 0 },
            ),
          ],
        )
        saved = routine.reload.markers.first[:payload]

        # The scramble is real, not hypothetical - assert it before relying on
        # the fix, so this test fails honestly if Postgres ever stops doing it.
        expect(saved.keys).to eq(%i[name which action position])

        expect(captured_for(saved)["params"]).to eq(["close", "all", 0])
      end

      # An arg left out must not slide every later arg onto the wrong slot.
      it "fills an unsent arg with the signature's default rather than shifting" do
        input = captured_for({ name: "HASS Blinds", which: "stairs" })

        expect(input["params"]).to eq(["open", "stairs", nil])
      end
    end

    it "keeps expect_result out of the row's sublabel args" do
      stub_execution("closed")
      tool = Buddy::Tools[:call_jil_function]
      ctx  = Buddy::ToolContext.new(user, conversation: convo)

      confirm = tool[:confirm].call({ name: "HASS Sensor State", sensor: "kennel", expect_result: true }, ctx)

      expect(confirm[:resolved][:fn_args]).to eq("sensor" => "kennel")
    end
  end

  describe "the schema" do
    before { Rails.root.glob("app/service/buddy/tools/*.rb").each { |f| load f } }

    it "is never offered - run_jil_task is how it's reached" do
      expect(Buddy::Tools.function_schemas.pluck(:name)).not_to include(:call_jil_function, :trigger_jil_task)
    end

    it "offers expect_result as a nullable boolean on the tool that reaches it" do
      schema = Buddy::Tools.function_schemas.find { |s| s[:name] == :run_jil_task }

      expect(schema[:parameters][:properties][:expect_result][:type]).to eq([:boolean, :null])
    end
  end
end
