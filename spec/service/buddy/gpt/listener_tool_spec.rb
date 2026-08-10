require "rails_helper"

# The syntax doc explains the shape; the examples are what stop a listener from
# parsing cleanly and then never firing. A key that doesn't exist in a scope's
# payload is invisible to every static check, so the only reliable source is
# listeners already working on the person's own tasks.
RSpec.describe Buddy::GPT::ListenerTool do
  let(:user)  { create(:user) }
  let(:convo) { user.byte_conversations.create!(mode: :buddy) }
  let(:tool)  { described_class.new(user, convo) }

  def task!(listener, name:, description: nil)
    Task.create!(
      user: user, name: name, listener: listener, description: description,
      code: "// noop", enabled: true
    )
  end

  def call(args={})
    JSON.parse(tool.call(args.stringify_keys))
  end

  it "returns the syntax guide" do
    result = call

    expect(result["syntax"]).to include("scope:key:value")
    expect(result["syntax"]).to include("substring")
  end

  it "returns real listeners off the person's own tasks" do
    task!("item:action:added", name: "List ping", description: "Pings when a list gains an item")

    examples = call["examples"]

    expect(examples).to include("listener" => "item:action:added", "does" => "Pings when a list gains an item")
  end

  it "falls back to the task name when it has no description" do
    task!("event:action:added", name: "Event logger")

    expect(call["examples"]).to include("listener" => "event:action:added", "does" => "Event logger")
  end

  it "puts the asked-for scope's examples first, since those key paths transfer" do
    task!("email:from:bank", name: "Bank mail")
    task!("item:action:added", name: "List ping")

    expect(call(scope: "item")["examples"].first["listener"]).to eq("item:action:added")
  end

  # A function task's listener is a signature, not a trigger pattern - copying
  # one would produce something that never fires.
  it "leaves function-signature listeners out" do
    task!('function("Temp" TAB Numeric)::Boolean', name: "Set temp")
    task!("item:action:added", name: "List ping")

    expect(call["examples"].pluck("listener")).to eq(["item:action:added"])
  end

  it "points the model at the observed payloads rather than at invention" do
    expect(call["next"]).to match(/payloads/)
    expect(call["next"]).to match(/never fires/)
  end

  # The examples are a THIN source, and they were the only one. Every appliance
  # in the house arrives on a task whose whole listener is the bare word
  # `hass-trigger`, so no example contains the word "dryer" or the keys it's
  # told apart by — and asked to watch the dryer, the model found the `laundry`
  # scope (a button, which only ever fires a start) and wrote a dead watch.
  describe "what the triggers really carry" do
    before do
      Rails.cache.clear
      Buddy::TriggerShapes.observe(user, "hass-trigger", { "device_name" => "Dryer", "type" => "stop" })
      Rails.cache.delete("buddy:shape:#{user.id}:hass-trigger")
      Buddy::TriggerShapes.observe(user, "hass-trigger", { "device_name" => "Washer", "type" => "start" })
    end

    it "lists each scope's real fields" do
      expect(call["payloads"]["hass-trigger"]).to include("device_name (string: Dryer | Washer)")
    end

    it "lists the values a field actually takes, so a plausible one isn't guessed" do
      expect(call["payloads"]["hass-trigger"]).to include("type (string: start | stop)")
    end

    it "names the house devices, which appear in no task and no example" do
      allow(Buddy::DeviceStates).to receive(:for_user).and_return([
        { device: "Dryer", state: "stop" },
        { device: "Washer", state: "stop" },
      ])

      expect(call["devices"]["names"]).to eq(%w[Dryer Washer])
    end

    it "leaves devices out entirely when the house has never reported" do
      allow(Buddy::DeviceStates).to receive(:for_user).and_return([])

      expect(call).not_to have_key("devices")
    end
  end

  # The scope index and the search are the discovery half. A scope fed by an
  # integration has no name anyone could guess (`hass-sensor`), and it appears
  # in no context section, so without these the only honest answer to "can you
  # watch the doorbell" is a wrong no.
  describe "discovery" do
    it "counts what's listening on each scope" do
      task!("item:action:added", name: "List ping")
      task!("item:action:removed", name: "List unping")
      task!("email:from:bank", name: "Bank mail")

      expect(call["scopes"]).to eq("item" => 2, "email" => 1)
    end

    it "puts the busiest scope first, so the index reads as a summary" do
      task!("email:from:bank", name: "Bank mail")
      task!("item:action:added", name: "List ping")
      task!("item:action:removed", name: "List unping")

      expect(call["scopes"].keys.first).to eq("item")
    end

    it "searches names, descriptions and listeners together" do
      task!("hass-sensor:location:doorbell", name: "Ring", description: "Pushes when the bell is rung")
      task!("item:action:added", name: "List ping")

      expect(call(about: "doorbell").fetch("matches").pluck("listener"))
        .to eq(["hass-sensor:location:doorbell"])
    end

    it "ranks a task matching more of the phrase above one matching less" do
      task!("hass-sensor:location:backyard", name: "Backyard camera")
      task!("hass-sensor:location:doorbell", name: "Front door camera")

      expect(call(about: "front door camera").fetch("matches").first["does"]).to eq("Front door camera")
    end

    # An omitted search is a different question from one that found nothing,
    # and an empty array would read as the latter.
    it "leaves the key out entirely when nothing was searched for" do
      expect(call).not_to have_key("matches")
    end
  end
end
