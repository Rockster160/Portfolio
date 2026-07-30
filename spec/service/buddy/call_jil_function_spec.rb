require "rails_helper"

# call_jil_function is a level-1 tool: it fires on the spot and normally drops a
# "Called X ✓" chip. When the person asked a QUESTION rather than giving a
# command, the function's RETURN VALUE is the answer, so it gets relayed into a
# fresh Buddy turn (same shape as check_weather) and the chip is suppressed.
RSpec.describe "call_jil_function tool" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

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

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
  end

  # The Jil executor itself is out of scope here; all this tool cares about is
  # the value coming back off `#result`.
  def stub_execution(result)
    allow_any_instance_of(Task).to receive(:execute)
      .and_return(instance_double(::Jil::Executor, result: result))
  end

  def run(payload)
    Buddy::ProposalBuilder.create(
      user: user, byte_message: msg, markers: [{ tool_name: :call_jil_function, payload: payload }],
    )
  end

  def chip
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
  end

  describe "a status question (expect_result)" do
    # Verbatim from prod execution 5219077, so the seed is written against what
    # these functions really return rather than a tidied-up guess.
    let(:real_output) { "laundry_gate is closed (raw state: off, last changed: 2026-07-30T02:14:14.188937+00:00)" }

    it "relays what the function returned into a follow-up reply instead of a chip" do
      stub_execution(real_output)

      result = run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })

      expect(result[:auto_ran]).to be(true)
      expect(chip).to be_nil
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt).with(
        hash_including(
          user:         user,
          conversation: convo,
          seed:         include(real_output).and(include("HASS Sensor State")),
        ),
      )
    end

    it "tells Buddy how to handle the raw internal key and UTC stamp it gets back" do
      stub_execution(real_output)

      run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })

      seed = nil
      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt) { |args| seed = args[:seed] }
      expect(seed).to include("UTC").and include("local 12-hour")
      expect(seed).to include("couldn't get a reading")
    end

    it "falls back to the chip when the function came back with nothing to say" do
      stub_execution("   ")

      run({ name: "HASS Sensor State", sensor: "laundry_gate", expect_result: true })

      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
      expect(chip.body).to eq("Called **HASS Sensor State**")
      expect(chip.metadata["detail"]).to include("call_jil_function")
    end
  end

  describe "a command (no expect_result)" do
    it "chips as before and never posts a second message" do
      stub_execution("ok")

      run({ name: "HASS Sensor State", sensor: "kennel" })

      expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
      expect(chip.body).to eq("Called **HASS Sensor State**")
      expect(chip.metadata["detail"]).to include("call_jil_function")
    end

    # Regression: the receipt used to read ctx.proposal["payload"], but level-1
    # tools run through ProposalBuilder#run_auto, which builds a ToolContext
    # WITHOUT a proposal. That raised NoMethodError on nil, got swallowed by
    # `safely`, and silently suppressed this chip on every single call.
    it "still names the task even though level 1 has no proposal in context" do
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

    it "drops the proposal rather than firing an actuator to satisfy a question" do
      allow_any_instance_of(Task).to receive(:execute).and_raise("should never run")

      result = run({ name: "HASS Blinds", action: "position", expect_result: true })

      expect(result[:auto_ran]).to be(false)
      expect(result[:action]).to be_nil
      expect(chip).to be_nil
    end

    it "still runs it normally as a command" do
      stub_execution("closed")

      run({ name: "HASS Blinds", action: "close" })

      expect(chip.body).to eq("Called **HASS Blinds**")
      expect(chip.metadata["detail"]).to include("call_jil_function")
    end

    it "allows a function that describes itself as reporting" do
      stub_execution("kennel is closed")

      run({ name: "HASS Sensor State", sensor: "kennel", expect_result: true })

      expect(Buddy::CompanionDelivery).to have_received(:deliver_prompt)
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
