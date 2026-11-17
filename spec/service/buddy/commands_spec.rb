require "rails_helper"

# A Jil task leaves a key with `Buddy.command("Hall Button")`, Buddy fills it
# from "set the hall button to ...", and the next run of the task runs what was
# saved there: tool calls straight away, or words handed back to Buddy.
RSpec.describe "Buddy commands" do
  let(:user) { create(:user) }
  let(:ctx)  { Buddy::ToolContext.new(user) }
  let(:tool) { Buddy::Tools[:set_command] }

  let!(:button) {
    Task.create!(
      user: user, name: "Hall Button", listener: "hall-button", enabled: true,
      code: %(cmd = Buddy.command("Hall Button")::Boolean)
    )
  }
  let!(:chill) {
    Task.create!(user: user, name: "Chill Mode", listener: "chill-mode", enabled: true, buddy_enabled: true, code: "")
  }

  let(:chill_steps) { JSON.generate([{ tool_name: :run_jil_task, payload: { name: "Chill Mode" } }]) }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  }

  def set!(payload)
    resolved = tool[:confirm].call(payload, ctx)[:resolved]
    tool[:execute].call(payload.merge(resolved), ctx)
  end

  describe "the keys" do
    it "are read off the tasks that call Buddy.command", :aggregate_failures do
      Task.create!(
        user: user, name: "Printer Panel", listener: "printer-panel", enabled: true,
        code: <<~'JIL',
          a = Buddy.command("Printer Top")::Boolean
          b = Buddy.command("hall button")::Boolean
        JIL
      )

      slots = Buddy::Commands.slots(user)
      expect(slots.pluck(:name)).to eq(["Hall Button", "Printer Top"])
      expect(slots.first[:tasks]).to contain_exactly("Hall Button", "Printer Panel")
    end

    it "leave out a task that's switched off" do
      button.update!(enabled: false)

      expect(Buddy::Commands.slots(user)).to be_empty
    end

    it "match loosely, but only the words of a real key", :aggregate_failures do
      expect(Buddy::Commands.slot(user, "button hall")[:name]).to eq("Hall Button")
      expect(Buddy::Commands.slot(user, "porch button")).to be_nil
    end

    it "are listed for the model with what each does now" do
      set!(key: "hall button", steps: chill_steps)

      expect(Buddy::Commands.roster(user)).to eq(["Hall Button (run jil task: Chill Mode)"])
    end
  end

  describe "set_command" do
    it "saves the steps under the key's own spelling", :aggregate_failures do
      set!(key: "hall button", steps: chill_steps)

      cmd = BuddyCommand.named(user, "Hall Button")
      expect(cmd.name).to eq("Hall Button")
      expect(cmd.steps).to eq([{ "tool_name" => "run_jil_task", "payload" => { "name" => "Chill Mode" } }])
      expect(cmd.say).to be_nil
    end

    it "saves words when that's what it's given" do
      set!(key: "Hall Button", say: "close whichever garage door is open")

      expect(BuddyCommand.named(user, "Hall Button").say).to eq("close whichever garage door is open")
    end

    it "replaces what was there" do
      set!(key: "Hall Button", steps: chill_steps)
      set!(key: "Hall Button", say: "tell me something nice")

      cmd = BuddyCommand.named(user, "Hall Button")
      expect([cmd.steps, cmd.say, BuddyCommand.count]).to eq([[], "tell me something nice", 1])
    end

    it "clears a key" do
      set!(key: "Hall Button", steps: chill_steps)
      set!(key: "Hall Button", clear: true)

      expect(BuddyCommand.named(user, "Hall Button")).to be_nil
    end

    it "refuses a key no task calls, naming the ones that exist" do
      expect {
        tool[:confirm].call({ key: "Porch Button", say: "lights" }, ctx)
      }.to raise_error(/the ones their automations have are Hall Button/)
    end

    it "refuses steps and words together" do
      expect {
        tool[:confirm].call({ key: "Hall Button", say: "lights", steps: chill_steps }, ctx)
      }.to raise_error(/ONE of/)
    end

    it "refuses a step that names nothing real" do
      bad = JSON.generate([{ tool_name: :run_jil_task, payload: { name: "Porch Lights" } }])

      expect { tool[:confirm].call({ key: "Hall Button", steps: bad }, ctx) }.to raise_error(/Porch Lights/)
    end

    it "refuses a step that runs the button's own task" do
      button.update!(buddy_enabled: true)
      loop_steps = JSON.generate([{ tool_name: :run_jil_task, payload: { name: "Hall Button" } }])

      expect {
        tool[:confirm].call({ key: "Hall Button", steps: loop_steps }, ctx)
      }.to raise_error(/is the automation that runs Hall Button/)
    end
  end

  describe "Buddy.command in Jil" do
    let(:code) { %(cmd = Buddy.command("Hall Button")::Boolean) }

    def press
      Jil::Executor.call(user, code, {}).ctx.dig(:vars, :cmd, :value)
    end

    it "validates" do
      expect { Jil::Validator.validate!(code) }.not_to raise_error
    end

    it "is false and does nothing when nothing is attached" do
      expect(Jil).not_to receive(:trigger)

      expect(press).to be(false)
    end

    it "runs saved steps straight away, with no model turn", :aggregate_failures do
      set!(key: "Hall Button", steps: chill_steps)
      allow(Jil).to receive(:trigger).and_call_original
      expect(BuddyDeliverWorker).not_to receive(:deliver_after_commit)

      expect(press).to be(true)
      expect(Jil).to have_received(:trigger).with(user, :"chill-mode", {}, auth: :buddy, auth_id: user.id)
      expect(BuddyCommand.named(user, "Hall Button").run_count).to eq(1)
    end

    it "hands saved words back to Buddy as a request", :aggregate_failures do
      set!(key: "Hall Button", say: "close whichever garage door is open")
      allow(BuddyDeliverWorker).to receive(:deliver_after_commit)

      expect(press).to be(true)
      seed = user.byte_messages.where(direction: :outbound).last
      expect(seed.body).to include(%(Hall Button just ran, and they set it to mean this: "close whichever garage door is open"))
      expect(seed.metadata).to include("kind" => "buddy_trigger", "hidden" => true)
      expect(BuddyDeliverWorker).to have_received(:deliver_after_commit).with(seed.id)
    end

    it "does not run itself from inside its own run" do
      cmd = BuddyCommand.create!(user: user, name: "Hall Button", say: "anything")
      Thread.current[:buddy_commands_running] = [cmd.id]

      expect(Buddy::Commands.run!(user, "Hall Button")).to be(false)
    ensure
      Thread.current[:buddy_commands_running] = nil
    end
  end
end
