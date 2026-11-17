require "rails_helper"

# A Jil task leaves a key with `Buddy.command("Hall Button")`, Buddy fills it
# from "set the hall button to ...", and the next run of the task runs the
# items saved there: tool calls straight away, `ask_buddy` handed back to Buddy.
RSpec.describe Buddy::Commands do
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

  let(:chill_item) { { tool_name: :run_jil_task, payload: { name: "Chill Mode" } } }
  let(:ask_item)   { { tool_name: :ask_buddy, payload: { text: "close whichever garage door is open" } } }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  }

  def set!(key, items)
    payload = { key: key, items: JSON.generate(items) }
    tool[:execute].call(payload.merge(tool[:confirm].call(payload, ctx)[:resolved]), ctx)
  end

  describe "the keys" do
    it "are read off the tasks that call Buddy.command, once each" do
      Task.create!(
        user: user, name: "Printer Panel", listener: "printer-panel", enabled: true,
        code: %(a = Buddy.command("Printer Top")::Boolean\nb = Buddy.command("hall button")::Boolean)
      )

      expect(described_class.keys(user)).to eq(["Hall Button", "Printer Top"])
    end

    it "leave out a task that's switched off" do
      button.update!(enabled: false)

      expect(described_class.keys(user)).to be_empty
    end

    it "match loosely, but only the words of a real key", :aggregate_failures do
      expect(described_class.key(user, "button hall")).to eq("Hall Button")
      expect(described_class.key(user, "porch button")).to be_nil
    end

    it "are listed for the model with what each does now" do
      set!("hall button", [chill_item, ask_item])

      expect(described_class.roster(user)).to eq([
        "Hall Button (run jil task: Chill Mode, ask Buddy: \"close whichever garage door is open\")",
      ])
    end
  end

  describe "set_command" do
    it "saves the items in the cache under the key's own spelling" do
      set!("hall button", [chill_item, ask_item])

      expect(described_class.items(user, "Hall Button")).to eq([
        { "tool_name" => "run_jil_task", "payload" => { "name" => "Chill Mode" } },
        { "tool_name" => "ask_buddy", "payload" => { "text" => "close whichever garage door is open" } },
      ])
    end

    it "replaces what was there, and an empty list clears it", :aggregate_failures do
      set!("Hall Button", [chill_item])
      set!("Hall Button", [ask_item])
      expect(described_class.items(user, "Hall Button").pluck("tool_name")).to eq(["ask_buddy"])

      set!("Hall Button", [])
      expect(described_class.items(user, "Hall Button")).to be_empty
    end

    it "refuses a key no task calls, naming the ones that exist" do
      expect {
        tool[:confirm].call({ key: "Porch Button", items: "[]" }, ctx)
      }.to raise_error(/the ones their automations have are Hall Button/)
    end

    it "refuses a tool call that names nothing real" do
      bad = JSON.generate([{ tool_name: :run_jil_task, payload: { name: "Porch Lights" } }])

      expect { tool[:confirm].call({ key: "Hall Button", items: bad }, ctx) }.to raise_error(/Porch Lights/)
    end

    it "refuses an ask_buddy with nothing to ask" do
      empty = JSON.generate([{ tool_name: :ask_buddy, payload: {} }])

      expect { tool[:confirm].call({ key: "Hall Button", items: empty }, ctx) }.to raise_error(/needs its `text`/)
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

    it "is false and does nothing when nothing is saved" do
      expect(Jil).not_to receive(:trigger)

      expect(press).to be(false)
    end

    it "runs saved tool calls straight away, with no model turn", :aggregate_failures do
      set!("Hall Button", [chill_item])
      allow(Jil).to receive(:trigger).and_call_original
      expect(BuddyDeliverWorker).not_to receive(:deliver_after_commit)

      expect(press).to be(true)
      expect(Jil).to have_received(:trigger).with(user, :"chill-mode", {}, auth: :buddy, auth_id: user.id)
    end

    it "hands an ask_buddy item back to Buddy as a request", :aggregate_failures do
      set!("Hall Button", [ask_item])
      allow(BuddyDeliverWorker).to receive(:deliver_after_commit)

      expect(press).to be(true)
      seed = user.byte_messages.where(direction: :outbound).last
      expect(seed.body).to include(%(Hall Button just ran, and they set it to mean this: "close whichever garage door is open"))
      expect(seed.metadata).to include("kind" => "buddy_trigger", "hidden" => true)
      expect(BuddyDeliverWorker).to have_received(:deliver_after_commit).with(seed.id)
    end

    it "does not press itself again from inside its own run" do
      button.update!(buddy_enabled: true, code: %(cmd = Buddy.command("Hall Button")::Boolean))
      set!("Hall Button", [{ tool_name: :run_jil_task, payload: { name: "Hall Button" } }])
      allow(Jil).to receive(:trigger).and_call_original

      expect(press).to be(true)
      expect(Jil).to have_received(:trigger).once
    end
  end
end
