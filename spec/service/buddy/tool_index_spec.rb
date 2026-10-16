require "rails_helper"

RSpec.describe Buddy::ToolIndex do
  let(:user) { User.me }

  def names(schemas)
    schemas.pluck(:name).map(&:to_sym)
  end

  def index_of(schemas)
    schemas.find { |schema| schema[:name] == described_class::NAME }
  end

  describe "summaries" do
    # The index line is all the model sees of an unloaded tool, so a tool
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

    it "offers the frame, the always tools and the index, and no indexed tool in full" do
      expect(names(stage_one)).to include(:get_context, :read_listener_guide, :remember, described_class::NAME)
      expect(names(stage_one)).to include(*always.pluck(:name))
      expect(names(stage_one) & indexed.pluck(:name)).to be_empty
    end

    it "lists every indexed tool by name and summary, and lets load_tools name only those" do
      index = index_of(stage_one)

      indexed.each { |tool| expect(index[:description]).to include("- #{tool[:name]}: #{tool[:summary]}") }
      expect(index[:parameters][:properties][:names][:items][:enum]).to match_array(indexed.map { |t| t[:name].to_s })
      expect(index[:description]).not_to include("- #{always.first[:name]}:")
    end

    it "adds a loaded tool's full schema after the fixed part, which never moves" do
      tool   = indexed.first
      loaded = described_class.schemas(user: user, loaded: [tool[:name]])

      expect(loaded.first(stage_one.length)).to eq(stage_one)
      expect(loaded.last).to eq(Buddy::Tools.function_schema(tool, user: user))
    end

    it "is far smaller than every schema in full" do
      expect(JSON.generate(stage_one).bytesize).to be < JSON.generate(described_class.everything(user: user)).bytesize / 3
    end
  end

  describe ".load" do
    it "opens the named tools and reports a name that isn't on the index" do
      loaded = Set.new
      tool   = described_class.indexed(user: user).first

      result = described_class.load({ "names" => [tool[:name].to_s, "made_up_tool"] }, user: user, loaded: loaded)

      expect(loaded).to contain_exactly(tool[:name])
      expect(result).to include(ok: true, loaded: [tool[:name]], unknown: [:made_up_tool])
    end

    it "answers not-ok when nothing it named exists" do
      result = described_class.load({ "names" => ["made_up_tool"] }, user: user, loaded: Set.new)

      expect(result[:ok]).to be(false)
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

    it "offers a tool in full from the round after it was loaded, to the end of the turn" do
      client = run([
        { tool_calls: [{ name: :load_tools, arguments: { "names" => ["search_memories"] } }] },
        { tool_calls: [lookup] },
        { tool_calls: [{ name: :get_context, arguments: { "sections" => nil } }] },
        { text: "Nothing about camping yet." },
      ])

      offered = client.calls.map { |request| names(request.tools) }
      expect(offered[0]).not_to include(:search_memories)
      expect(offered[1..]).to all(include(:search_memories))
    end

    it "doesn't count a round that only loaded tools toward the cap" do
      rounds = [{ tool_calls: [{ name: :load_tools, arguments: { "names" => ["search_memories"] } }] }]
      rounds += Array.new(8) { { tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] } }
      client = run(rounds)

      expect(client.calls.length).to eq(Buddy::GPT::Turn::MAX_ROUNDS + 1)
    end

    # The model can only name what it has seen, so a call it makes straight off
    # the index line is honored rather than refused - and the next round holds
    # the schema it skipped.
    it "runs a tool called off the index without loading it, and loads it for the next round" do
      client = run([{ tool_calls: [lookup] }, { text: "Nothing about camping yet." }])

      expect(names(client.calls.first.tools)).not_to include(:search_memories)
      expect(names(client.calls.last.tools)).to include(:search_memories)
      output = client.calls.last.input.find { |item| item[:type] == :function_call_output }
      expect(JSON.parse(output[:output])["status"]).not_to eq("failed")
    end

    it "points a failed unloaded call at the instructions it skipped" do
      bad    = { name: :search_memories, arguments: { "min_severity" => "lots" } }
      client = run([{ tool_calls: [bad] }, { text: "Hmm." }])

      output = client.calls.last.input.find { |item| item[:type] == :function_call_output }
      expect(JSON.parse(output[:output])["how"]).to eq(described_class::UNREAD_RETRY)
    end

    it "leaves a seed's named tools in full, with no index" do
      seed   = { "kind" => "buddy_trigger", "hidden" => true, "seed_tools" => %w[search_memories] }
      client = run([{ text: "ok" }], metadata: seed)

      expect(names(client.calls.first.tools)).to eq([:search_memories])
    end
  end
end
