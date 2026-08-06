require "rails_helper"

# call_jil_function acts AND reports, inside the turn. The function runs while
# the model is still deciding what to say, and its return value goes back as the
# tool output, so the reply is written knowing the outcome.
#
# It used to fire after the reply and relay a return value through a whole
# second turn. Prod 2789 is what that cost: "Close the garage" got "Kk! Garage's
# closing." written 17 seconds before the call landed, alongside a separate
# read whose (pre-toggle) answer became the follow-up message.
RSpec.describe "call_jil_function tool" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  # Mirrors prod task 435: a sensor reader whose whole point is what it returns.
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
    # Verbatim from prod execution 5219077, so this is written against what
    # these functions really return rather than a tidied-up guess.
    let(:real_output) { "laundry_gate is closed (raw state: off, last changed: 2026-07-30T02:14:14.188937+00:00)" }

    it "hands what the function returned back to the model in the same turn" do
      stub_execution(real_output)

      result = run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })

      expect(result[:status]).to eq(:answered)
      expect(result[:answer]).to include("laundry_gate is closed")
    end

    # Prod 2636: handed `18:58:03+00:00` and told to convert it, the model
    # answered "6:58 PM" — the same digits with the offset thrown away, six
    # hours out. It reads a clock fine and moves one badly, so the conversion
    # happens before it ever sees the line (see Buddy::RawOutput).
    it "localizes a UTC stamp rather than asking the model to convert one" do
      stub_execution(real_output)

      result = travel_to(Time.utc(2026, 7, 31, 18, 0, 0)) {
        run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })
      }

      expect(result[:answer]).to include("8:14 PM on Jul 29")
      expect(result[:answer]).not_to include("02:14:14")
      expect(result[:answer]).not_to include("+00:00")
    end

    it "tells the model to drop the internal key, leave the time be, and never invent a state" do
      stub_execution(real_output)

      result = run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })

      expect(result[:how]).to include("`laundry_gate`")
      expect(result[:how]).to include("ALREADY their local time")
      expect(result[:how]).to include("couldn't get a reading")
    end

    # The 2789 shape: the function reports that it deliberately did nothing.
    # Byte has to relay that instead of narrating the action it asked for.
    it "warns the model that a function may report having done nothing" do
      stub_execution("The garage was already closed, so nothing was sent.")

      result = run({ name: "HASS Sensor State", sensor: "kennel" })

      expect(result[:answer]).to eq("The garage was already closed, so nothing was sent.")
      expect(result[:how]).to include("already that way")
    end

    it "says plainly that a silent command returned nothing rather than leaving it open" do
      stub_execution("   ")

      result = run({ name: "HASS Sensor State", sensor: "kennel" })

      expect(result).not_to have_key(:answer)
      expect(result[:how]).to include("returned nothing to report")
      expect(result[:how]).to include("don't invent a result")
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

    it "offers expect_result as a nullable boolean" do
      schema = Buddy::Tools.function_schemas.find { |s| s[:name] == :call_jil_function }

      expect(schema[:parameters][:properties][:expect_result][:type]).to eq([:boolean, :null])
    end
  end
end
