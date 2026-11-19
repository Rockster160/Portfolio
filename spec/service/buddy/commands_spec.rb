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
      expect(button.reload.archived_at).to be_nil
    end

    it "adds to what's there when asked to, leaving the saved arguments as they were" do
      tree = { tool_name: :call_jil_function, payload: { name: "Chill Mode", Target: "christmas_tree" } }
      allow(Buddy::Routines).to receive(:sanitize) { |rows, _ctx| rows }
      set!("Hall Button", [tree])

      payload = { key: "Hall Button", items: JSON.generate([ask_item]), add: true }
      tool[:execute].call(payload.merge(tool[:confirm].call(payload, ctx)[:resolved]), ctx)

      expect(described_class.items(user, "Hall Button")).to eq([
        { "tool_name" => "call_jil_function", "payload" => { "name" => "Chill Mode", "Target" => "christmas_tree" } },
        { "tool_name" => "ask_buddy", "payload" => { "text" => "close whichever garage door is open" } },
      ])
    end

    it "shows every argument a saved item carries, so a replace can keep it whole" do
      described_class.save!(user, "Hall Button", [
        { "tool_name" => "call_jil_function", "payload" => { "name" => "HASS Switch", "Action" => "toggle", "Target" => "christmas_tree" } },
      ])

      expect(described_class.roster(user)).to eq([
        "Hall Button (call jil function: HASS Switch (Action: toggle, Target: christmas_tree))",
      ])
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

  describe "programming a button or phrase that has no key yet" do
    before {
      user.caches.dig_set(:hass, "Btn#9", { state: "single", at: 1 })
      user.caches.dig_set(:hass, "Remote", { state: "hold-3", at: 1 })
      user.caches.dig_set(:hass, "Porch Light", { state: "on", at: 1 })
    }

    def program!(key, items, **trigger)
      payload = { key: key, items: JSON.generate(items), **trigger }
      tool[:execute].call(payload.merge(tool[:confirm].call(payload, ctx)[:resolved]), ctx)
    end

    it "knows the buttons by the presses they've reported, and lists the ones with nothing on them" do
      expect(described_class.buttons(user)).to eq(["Btn#9", "Remote"])
      expect(described_class.button(user, "button 9")).to eq("Btn#9")
      expect(described_class.roster(user)).to include("button Btn#9 (nothing on it yet)")
    end

    it "makes a Jil task that runs the key on that button's press, and fills it", :aggregate_failures do
      program!("Button 9", [chill_item], button: "button 9")

      task = user.tasks.find_by!(name: "Button 9")
      expect(task.listener).to eq(%(hass-button:device_name::"Btn#9"))
      expect { Jil::Validator.validate!(task.code) }.not_to raise_error
      expect(described_class.items(user, "Button 9").pluck("tool_name")).to eq(["run_jil_task"])
      expect(described_class.roster(user)).to include("Button 9 (pressing Btn#9: run jil task: Chill Mode)")
      expect(described_class.roster(user)).not_to include("button Btn#9 (nothing on it yet)")

      fires = ->(data) { Jil::ListenerMatch.call(task.listener, :"hass-button", data) }
      expect(fires.call({ device_name: "Btn#9", type: "single" })).to be(true)
      expect(fires.call({ device_name: "Btn#4", type: "single" })).to be(false)
    end

    it "fills the same key when the button is programmed again, whatever it's called" do
      program!("Button 9", [chill_item], button: "Btn#9")
      program!("Christmas tree button", [ask_item], button: "button 9")

      expect(user.tasks.where("code LIKE ?", "%Buddy.command(%").count).to eq(2)
      expect(described_class.items(user, "Button 9").pluck("tool_name")).to eq(["ask_buddy"])
    end

    it "still knows a button programmed under its own name", :aggregate_failures do
      program!("Btn#9", [chill_item], button: "Btn#9")
      program!("Btn#9", [ask_item], button: "Btn#9")

      expect(described_class.button(user, "button 9")).to eq("Btn#9")
      expect(user.tasks.where(name: "Btn#9").count).to eq(1)
      expect(described_class.items(user, "Btn#9").pluck("tool_name")).to eq(["ask_buddy"])
    end

    it "listens for one kind of press when it's given" do
      program!("Remote hold", [chill_item], button: "remote", press: "hold")

      task = user.tasks.find_by!(name: "Remote hold")
      expect(Jil::ListenerMatch.call(task.listener, :"hass-button", { device_name: "Remote", type: "hold" })).to be(true)
      expect(Jil::ListenerMatch.call(task.listener, :"hass-button", { device_name: "Remote", type: "single" })).to be(false)
    end

    it "listens for a phrase said to Jarvis" do
      program!("Movie time", [chill_item], phrase: "Movie time!")

      task = user.tasks.find_by!(name: "Movie time")
      expect(Jil::ListenerMatch.call(task.listener, :tell, { words: "movie time", full: "movie time" })).to be(true)
      expect(Jil::ListenerMatch.call(task.listener, :tell, { words: "no movie time", full: "no movie time" })).to be(false)
      expect(described_class.roster(user)).to include(%(Movie time (saying "movie time": run jil task: Chill Mode)))
    end

    it "refuses a button that has never been pressed, naming the ones that have" do
      expect {
        tool[:confirm].call({ key: "Button 12", items: "[]", button: "button 12" }, ctx)
      }.to raise_error(/no button called "button 12".*Btn#9 and Remote/)
      expect(user.tasks.where(name: "Button 12")).to be_empty
    end

    it "removes the task it made when the key is cleared", :aggregate_failures do
      program!("Button 9", [chill_item], button: "button 9")
      program!("Button 9", [], button: "button 9")

      expect(user.tasks.active.where(name: "Button 9")).to be_empty
      expect(described_class.roster(user)).to include("button Btn#9 (nothing on it yet)")

      program!("Christmas tree button", [ask_item], button: "button 9")
      again = user.tasks.active.find_by!(name: "Christmas tree button")
      expect(again.listener).to eq(%(hass-button:device_name::"Btn#9"))
    end

    it "stops a cleared phrase from matching at all" do
      program!("Movie time", [chill_item], phrase: "movie time")
      program!("movie time", [])

      expect(user.tasks.active.where(name: "Movie time")).to be_empty
    end

    it "leaves a task alone when it does more than run the key" do
      program!("Button 9", [chill_item], button: "button 9")
      task = user.tasks.find_by!(name: "Button 9")
      task.update!(code: "#{task.code}\nGlobal.stop_propagation()::Any")
      program!("Button 9", [])

      expect(task.reload.archived_at).to be_nil
    end

    it "refuses to make a task just to clear it" do
      expect {
        tool[:confirm].call({ key: "Button 9", items: "[]", button: "button 9" }, ctx)
      }.to raise_error(/pressing Btn#9 has nothing on it to clear/)
      expect(user.tasks.where(name: "Button 9")).to be_empty
    end

    it "refuses a new key named the same as one that runs from something else" do
      expect {
        tool[:confirm].call({ key: "hall button", items: "[]", button: "button 9" }, ctx)
      }.to raise_error(/already runs from something else/)
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

    # The press is the whole request, so a step that worked leaves nothing in
    # the thread to read.
    it "says nothing in the thread when its steps work", :aggregate_failures do
      set!("Hall Button", [chill_item])

      expect(press).to be(true)
      expect(user.byte_messages.where(direction: :inbound).not_hidden).to be_empty
      expect(user.byte_messages.where("metadata->>'kind' = 'buddy_activity'").count).to eq(1)
    end

    it "shows a step that failed" do
      set!("Hall Button", [chill_item])
      allow(Buddy::Tools).to receive(:dispatch).and_return({ ok: false, error: "the house didn't answer" })

      press

      chips = user.byte_messages.not_hidden.where("metadata->>'kind' = 'buddy_activity'")
      expect(chips.map { |chip| chip.metadata["ok"] }).to eq([false])
    end

    describe "toggling a list item" do
      let(:list) { create(:list, user: user, name: "GO") }
      let!(:section) { Section.create!(list: list, name: "Rocco", color: "#888888") }

      before { set!("Hall Button", [{ tool_name: :toggle_list_item, payload: { list: "GO", item: "Watch Charging" } }]) }

      it "adds it when it's missing and takes it off when it's there, in the section it was in", :aggregate_failures do
        list.list_items.create!(name: "Watch Charging", section: section).soft_destroy
        expect(list.list_items.reload.pluck(:name)).to be_empty

        press
        expect(list.list_items.reload.pluck(:name, :section_id)).to eq([["Watch Charging", section.id]])

        press
        expect(list.list_items.reload.pluck(:name)).to be_empty
        expect(user.byte_messages.where(direction: :inbound).not_hidden).to be_empty
      end
    end

    describe "an item that only runs sometimes" do
      let(:workout) { { find: "action_events", query: 'name:"Workout"' } }

      before {
        set!("Hall Button", [
          chill_item.merge(only_if: [workout.merge(expect: "found")]),
          ask_item.merge(only_if: [workout.merge(expect: "missing")]),
        ])
        allow(Jil).to receive(:trigger).and_call_original
        allow(BuddyDeliverWorker).to receive(:deliver_after_commit)
      }

      it "is saved with its condition, and says so" do
        expect(described_class.roster(user).first).to include('only if any action events match `name:"Workout"`')
      end

      it "runs only the items whose conditions hold, with no model turn", :aggregate_failures do
        ActionEvent.create!(user: user, name: "Workout", timestamp: Time.current)

        press

        expect(Jil).to have_received(:trigger).with(user, :"chill-mode", {}, auth: :buddy, auth_id: user.id)
        expect(BuddyDeliverWorker).not_to have_received(:deliver_after_commit)
      end

      it "skips the ones that don't" do
        press

        expect(Jil).not_to have_received(:trigger)
        expect(BuddyDeliverWorker).to have_received(:deliver_after_commit).once
      end
    end

    it "skips an item whose condition can't be answered, and says so" do
      described_class.save!(user, "Hall Button", [
        { "tool_name" => "run_jil_task", "payload" => { "name" => "Chill Mode" }, "only_if" => { "kind" => "jil", "task" => "Gone", "expect" => "truthy" } },
      ])
      expect(Jil).not_to receive(:trigger)

      press

      chip = user.byte_messages.not_hidden.find_by!("metadata->>'kind' = 'buddy_activity'")
      expect(chip.metadata["ok"]).to be(false)
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
