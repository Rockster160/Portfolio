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

  it "tells the model to copy key paths rather than invent them" do
    expect(call["next"]).to match(/rather than inventing them/)
  end
end
