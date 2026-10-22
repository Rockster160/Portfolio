require "rails_helper"

# Every Jil task Buddy may reach goes through one tool. The task's listener
# says whether it's a function (called with arguments, returns a value) or a
# trigger (its scope fired with data), so the model only has to name it - and
# a wrong shape for that kind is refused with what the task actually takes.
RSpec.describe "run_jil_task tool" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  let!(:skip_nap) {
    Task.create!(
      user: user, name: "Whisper Skip Nap", listener: "function()::String", code: "// noop",
      enabled: true, buddy_enabled: true, description: "Skips Whisper's next nap."
    )
  }
  let!(:tesla) {
    Task.create!(
      user: user, name: "Tesla Start", listener: 'function("Temp" TAB Numeric BR "Dest" TAB String)::Boolean',
      code: "// noop", enabled: true, buddy_enabled: true, description: "Starts the car."
    )
  }
  let!(:laundry) {
    Task.create!(
      user: user, name: "Laundry Button", listener: 'hass-button:device_name::"Laundry Button"',
      code: "// noop", enabled: true, buddy_enabled: true, description: "Starts the laundry timer."
    )
  }
  let!(:chill) {
    Task.create!(
      user: user, name: "Chill Mode", listener: "chill-mode", code: "// noop",
      enabled: true, buddy_enabled: true, description: "Dims the lights."
    )
  }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def run(payload)
    Buddy::GPT::Turn.resolve_call(
      Buddy::Tools[:run_jil_task],
      { name: "run_jil_task", arguments: payload, call_id: "c1" },
      user: user, conversation: convo,
    ).first
  end

  def chip
    convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
  end

  describe "a function" do
    it "calls it with no arguments and hands back what it said" do
      allow_any_instance_of(Task).to receive(:execute).and_return(instance_double(::Jil::Executor, result: "Next nap is at 5pm"))

      result = run({ name: "Whisper Skip Nap" })

      expect(result[:status]).to eq(:answered)
      expect(result[:answer]).to eq("Next nap is at 5pm")
      expect(chip.body).to eq("Called **Whisper Skip Nap**")
    end

    it "passes its arguments in signature order" do
      allow_any_instance_of(Task).to receive(:execute) { |task, input, **|
        expect(task).to eq(tesla)
        expect(input).to include("temp" => 72, "dest" => "Home", "params" => [72, "Home"])
        instance_double(::Jil::Executor, result: nil)
      }

      expect(run({ name: "Tesla Start", args: { dest: "Home", temp: 72 } })[:status]).to eq(:answered)
    end

    it "refuses an argument the signature doesn't have, naming the ones it does" do
      expect_any_instance_of(Task).not_to receive(:execute)

      result = run({ name: "Tesla Start", args: { temperature: 72 } })

      expect(result.to_s).to include("Nothing ran: Tesla Start takes `temp`, `dest`", "`temperature` would go nowhere")
    end

    it "refuses arguments to one that takes none" do
      expect(run({ name: "Whisper Skip Nap", args: { when: "5pm" } }).to_s).to include("takes no arguments")
    end

    it "reads data sent in place of its arguments as the arguments" do
      allow_any_instance_of(Task).to receive(:execute) { |_task, input, **|
        expect(input).to include("temp" => "72", "dest" => "Home")
        instance_double(::Jil::Executor, result: nil)
      }

      expect(run({ name: "Tesla Start", data: "temp:72 dest:Home" })[:status]).to eq(:answered)
    end

    it "still refuses data whose keys the signature doesn't have" do
      expect(run({ name: "Tesla Start", data: "temperature:72" })[:error]).to include("`temperature` would go nowhere")
    end

    it "prefers a function when the call carries arguments" do
      Task.create!(
        user: user, name: "Tesla Start Scene", listener: "tesla-start-scene", code: "// noop",
        enabled: true, buddy_enabled: true
      )
      allow_any_instance_of(Task).to receive(:execute) { |task, *, **|
        expect(task).to eq(tesla)
        instance_double(::Jil::Executor, result: nil)
      }
      expect(Jil).not_to receive(:trigger)

      run({ name: "Tesla", args: { temp: 70 } })
    end
  end

  describe "a trigger" do
    it "fires its scope with the data its listener wants, and says what it said" do
      fired = laundry.tap { |t| allow(t).to receive(:last_message).and_return("Laundry timer started") }
      expect(Jil).to receive(:trigger).with(user, :"hass-button", { device_name: "Laundry Button" }, anything).and_return([fired])

      result = run({ name: "Laundry Button", data: "device_name:Laundry Button" })

      expect(result[:status]).to eq(:answered)
      expect(result[:answer]).to eq("Laundry timer started")
      expect(chip.body).to eq("Fired **Laundry Button**")
    end

    it "fires a bare scope with no data at all" do
      expect(Jil).to receive(:trigger).with(user, :"chill-mode", {}, anything).and_return([])

      result = run({ name: "Chill Mode" })

      expect(result[:how]).to include("It fired")
    end

    it "refuses data its listener won't match, before anything fires" do
      expect(Jil).not_to receive(:trigger)

      result = run({ name: "Laundry Button", data: "device_name:Dryer" })

      expect(result[:error]).to include('listens for `hass-button:device_name::"Laundry Button"`', "doesn't satisfy it")
    end

    it "reads arguments sent in place of data as the data" do
      expect(Jil).to receive(:trigger).with(user, :"hass-button", { device_name: "Laundry Button" }, anything).and_return([])

      run({ name: "Laundry Button", args: { device_name: "Laundry Button" } })
    end

    it "does not answer a question with one that changes something" do
      expect(Jil).not_to receive(:trigger)

      expect(run({ name: "Chill Mode", expect_result: true }).to_s).to include("changes something rather than reporting")
    end
  end

  it "says nothing matched when nothing does" do
    expect(run({ name: "Nothing Here" }).to_s).to include("no Jil task matches")
  end

  it "takes the exact name over a longer one of the other kind" do
    Task.create!(
      user: user, name: "Chill Mode Function", listener: "function()::String", code: "// noop",
      enabled: true, buddy_enabled: true
    )
    expect(Jil).to receive(:trigger).with(user, :"chill-mode", {}, anything).and_return([])

    run({ name: "Chill Mode" })
  end
end
