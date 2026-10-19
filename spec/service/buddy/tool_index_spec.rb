require "rails_helper"

RSpec.describe Buddy::ToolIndex do
  let(:user) { User.me }

  def names(schemas)
    schemas.pluck(:name).map(&:to_sym)
  end

  describe "summaries" do
    # The summary is all the model sees of an unopened tool, so a tool
    # without one is a tool nothing can choose.
    it "gives every registered tool a short one" do
      Buddy::Tools.all.each { |tool| # rubocop:disable Rails/FindEach -- an Array, not a relation
        expect(tool[:summary]).to be_present, "#{tool[:name]} has no summary"
        expect(tool[:summary].length).to be <= Buddy::Tools::SUMMARY_MAX, "#{tool[:name]}'s summary is too long"
      }
    end

    it "refuses to register a tool without one" do
      expect {
        Buddy::Tools.register(
          name:        :spec_unsummarized,
          summary:     " ",
          description: "spec-only",
          args:        {},
          confirm:     ->(_p, _c) { { summary: "x", resolved: {} } },
          label:       ->(_p, _c) { "x" },
          execute:     ->(_p, _c) { {} },
          receipt:     ->(_r, _c) { "x" },
        )
      }.to raise_error(ArgumentError, /summary/)
      expect(Buddy::Tools.known?(:spec_unsummarized)).to be(false)
    end
  end

  describe ".schemas" do
    let(:stage_one) { described_class.schemas(user: user) }
    let(:indexed)   { described_class.indexed(user: user) }
    let(:always)    { Buddy::Tools.offered(user: user).select { |tool| Buddy::Tools.always?(tool) } }

    def schema_for(schemas, name)
      schemas.find { |schema| schema[:name].to_s == name.to_s }
    end

    it "offers the frame and the always tools in full" do
      expect(names(stage_one)).to include(:get_context, :read_listener_guide, :remember)
      always.each { |tool| expect(schema_for(stage_one, tool[:name])).to eq(Buddy::Tools.function_schema(tool, user: user)) }
    end

    # The model picks a tool by its name in the list, so every tool is in the
    # list by name - only what it says, and what it takes, waits to be opened.
    it "lists every other tool by name with only its summary and no arguments" do
      indexed.each { |tool|
        entry = schema_for(stage_one, tool[:name])

        expect(entry[:description]).to start_with(tool[:summary])
        expect(entry[:parameters][:properties]).to be_empty
      }
    end

    # A request names the thing ("the TV", "Whisper's nap"), and the tool that
    # reaches it only says "automations" - so the person's own ones are listed
    # by name on the entry, and stay on it once it's opened.
    it "lists the person's own automations on the tools that reach them" do
      Task.create!(user: user, name: "HASS TV", listener: "function(\"Action\" TAB String)::String",
        code: "// noop", enabled: true, buddy_enabled: true)
      Task.create!(user: user, name: "Good Morning", listener: "good-morning",
        code: "// noop", enabled: true, buddy_enabled: true)

      expect(schema_for(stage_one, :call_jil_function)[:description]).to include("Theirs:", "HASS TV")
      expect(schema_for(stage_one, :call_jil_function)[:description]).not_to include("Good Morning")
      expect(schema_for(stage_one, :trigger_jil_task)[:description]).to include("Good Morning")
      expect(schema_for(stage_one, :trigger_jil_task)[:description]).not_to include("HASS TV")

      opened = described_class.schemas(user: user, loaded: [:call_jil_function])
      expect(schema_for(opened, :call_jil_function)[:description]).to include("HASS TV")
    end

    it "swaps an opened tool's summary for its full schema, in the same place" do
      tool   = indexed.first
      opened = described_class.schemas(user: user, loaded: [tool[:name]])

      expect(names(opened)).to eq(names(stage_one))
      expect(schema_for(opened, tool[:name])).to eq(Buddy::Tools.function_schema(tool, user: user))
    end

    it "is far smaller than every schema in full" do
      expect(JSON.generate(stage_one).bytesize).to be < JSON.generate(described_class.everything(user: user)).bytesize / 3
    end
  end

  describe ".opening?" do
    it "is a tool on the index that hasn't been opened yet" do
      tool = described_class.indexed(user: user).first

      expect(described_class.opening?(tool[:name], {}, loaded: Set.new)).to be(true)
      expect(described_class.opening?(tool[:name], {}, loaded: Set[tool[:name]])).to be(false)
      expect(described_class.opening?(:get_context, {}, loaded: Set.new)).to be(false)
    end

    it "is never a call that carries arguments, which is the tool being used" do
      tool = described_class.indexed(user: user).first

      expect(described_class.opening?(tool[:name], { "query" => "x" }, loaded: Set.new)).to be(false)
    end

    it "never counts an always tool, which arrives in full" do
      tool = Buddy::Tools.offered(user: user).find { |t| Buddy::Tools.always?(t) }

      expect(described_class.opening?(tool[:name], {}, loaded: Set.new)).to be(false)
    end
  end

  describe "in a turn" do
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
    }
    let(:lookup) { { name: :search_memories, arguments: { "query" => "camping" } } }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
    end

    def run(rounds, metadata: {})
      message = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "what have you kept about camping",
        metadata: metadata
      )
      client = FakeBuddyClient.new(rounds)
      Buddy::GPT::Turn.run!(message, client: client)
      client
    end

    let(:pick) { { name: :search_memories, arguments: {} } }

    it "opens a picked tool without running it, and offers it in full to the end of the turn" do
      client = run([
        { tool_calls: [pick] },
        { tool_calls: [lookup] },
        { tool_calls: [{ name: :get_context, arguments: { "sections" => nil } }] },
        { text: "Nothing about camping yet." },
      ])

      offered = client.calls.map { |request| request.tools.find { |t| t[:name].to_s == "search_memories" } }
      expect(offered[0][:parameters][:properties]).to be_empty
      expect(offered[1..]).to all(eq(Buddy::Tools.function_schema(Buddy::Tools[:search_memories], user: user)))

      opened = client.calls[1].input.find { |item| item[:type] == :function_call_output }
      expect(JSON.parse(opened[:output])["how"]).to start_with("Nothing has happened yet")
    end

    it "doesn't count a round that only opened tools toward the cap" do
      rounds = [{ tool_calls: [pick] }]
      rounds += Array.new(8) { { tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] } }
      client = run(rounds)

      expect(client.calls.length).to eq(Buddy::GPT::Turn::MAX_ROUNDS + 1)
    end

    # A pick has no arguments, so it must never reach the tool: "cancel my
    # timers" picking cancel_timer would otherwise run it with nothing to go on.
    it "never runs an acting tool on its pick" do
      expect(Buddy::Tools[:cancel_timer][:execute]).not_to receive(:call)
      client = run([{ tool_calls: [{ name: :cancel_timer, arguments: {} }] }, { text: "Which one?" }])

      expect(names(client.calls.last.tools)).to include(:cancel_timer)
      expect(convo.byte_messages.where("metadata ? 'buddy_action'").count).to eq(0)
    end

    it "leaves a seed's named tools in full, with no index" do
      seed   = { "kind" => "buddy_trigger", "hidden" => true, "seed_tools" => %w[search_memories] }
      client = run([{ text: "ok" }], metadata: seed)

      expect(names(client.calls.first.tools)).to eq([:search_memories])
    end
  end
end
