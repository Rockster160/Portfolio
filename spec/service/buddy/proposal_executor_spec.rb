require "rails_helper"

RSpec.describe Buddy::ProposalExecutor do
  let(:user) { FactoryBot.create(:user) }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "T") }
  let(:msg)   { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hi") }

  before do
    @executed = []
    executed = @executed
    Buddy::Tools.register(
      name:        :spec_track,
      summary:     "spec-only",
      description: "tracks executions",
      args:        { tag: { type: :string, required: true } },
      confirm:     ->(p, _) { { summary: "Do #{p[:tag]}?", resolved: {} } },
      label:       ->(p, _) { p[:tag].to_s },
      execute:     ->(p, _) { executed << p[:tag]; { echoed: p[:tag] } },
      receipt:     ->(r, _) { "Did #{r[:echoed]}" },
    )
  end

  def row(id, tag, tool: "spec_track", count: 1)
    { "id" => id, "label" => tag, "tool_name" => tool, "payload" => { "tag" => tag }, "count" => count, "status" => "pending" }
  end

  def action_with(buttons, decision: {})
    ByteAction.create!(
      user:              user,
      byte_conversation: convo,
      byte_message:      msg,
      kind:              :custom,
      tool_name:         "buddy_proposals",
      multi_select:      true,
      buttons:           buttons,
      decision:          decision,
      tool_input:        {},
    )
  end

  def status_of(action, id)
    action.buttons.find { |b| b["id"] == id }["status"]
  end

  describe "a decided checklist" do
    it "runs checked proposals and cancels unchecked ones", :aggregate_failures do
      action = action_with([row(1, "A"), row(2, "B")], decision: { "value" => [1] })

      described_class.perform(action.id)
      action.reload

      expect(@executed).to eq(["A"])
      expect(status_of(action, 1)).to eq("executed")
      expect(status_of(action, 2)).to eq("cancelled")
    end

    it "loops the executor `count` times when count > 1", :aggregate_failures do
      action = action_with([row(1, "A", count: 5)], decision: { "value" => [1] })

      described_class.perform(action.id)

      expect(@executed).to eq(["A"] * 5)
      expect(action.reload.buttons.first["status"]).to eq("executed")
    end
  end

  describe "checkbox taps, one row at a time" do
    let(:action) { action_with([row(1, "A"), row(2, "B")]) }

    # The untouched row stays live, which is the whole point of incremental.
    it "runs only the requested row, never twice, and decides the action once every row is resolved", :aggregate_failures do
      described_class.perform(action.id, [1])
      action.reload
      expect(@executed).to eq(["A"])
      expect(status_of(action, 1)).to eq("executed")
      expect(status_of(action, 2)).to eq("pending")
      expect(action).to be_pending

      described_class.perform(action.id, [1])       # repeat tap / stale job
      expect(@executed).to eq(["A"])

      described_class.perform(action.id, [1, 2])    # full set resent; only B is new
      expect(@executed).to eq(["A", "B"])
      action.reload
      expect(action).to be_decided
      expect(action.buttons.map { |b| b["status"] }).to all(eq("executed"))
    end
  end

  # THE ROW IS THE RECEIPT: it ticks, locks, and carries the tool's own words,
  # so nothing is posted under the card repeating it.
  describe "the receipt" do
    def register(name, execute:, receipt:)
      Buddy::Tools.register(
        name:        name,
        summary:     "spec-only",
        description: "spec-only",
        args:        {},
        confirm:     ->(_p, _) { { summary: "#{name}?", resolved: {} } },
        label:       ->(_p, _) { name.to_s },
        execute:     execute,
        receipt:     receipt,
      )
    end

    it "rides on the row in the tool's own words, and posts nothing into the thread", :aggregate_failures do
      action = action_with([row(1, "A"), row(2, "B")])

      expect { described_class.perform(action.id, [1, 2]) }.not_to change(ByteMessage, :count)

      expect(action.reload.buttons.find { |b| b["id"] == 1 }["receipt"]).to eq("Did A")
    end

    it "leaves the row bare when the tool declines a receipt", :aggregate_failures do
      register(:spec_quiet, execute: ->(_p, _) { {} }, receipt: ->(_r, _) {})
      action = action_with([row(1, "Quiet", tool: "spec_quiet")])

      described_class.perform(action.id, [1])

      expect(action.reload.buttons.first["status"]).to eq("executed")
      expect(action.buttons.first["receipt"]).to be_blank
    end

    # A failed row is red with the error inline on it.
    it "marks a failure on the row and posts nothing for it either", :aggregate_failures do
      register(:spec_boom, execute: ->(_p, _) { raise "nope" }, receipt: ->(_r, _) { "never reached" })
      action = action_with([row(1, "Boom", tool: "spec_boom")])

      expect { described_class.perform(action.id, [1]) }.not_to change(ByteMessage, :count)
      expect(action.reload.buttons.first["status"]).to eq("failed")
      expect(action.buttons.first["error_message"]).to be_present
    end
  end

  it "names only tools that exist as the ones that take a record away" do
    missing = described_class::UNDOING_TOOLS.reject { |name| Buddy::Tools[name.to_sym] }

    expect(missing).to be_empty
  end

  # An undo and the re-credit replacing it, ticked at once: the removal has to
  # settle first, or the new completion's cooldown anchors on the row about to
  # be deleted.
  describe "the order rows run in" do
    let(:pair) { [row(1, "create"), row(2, "undo", tool: "spec_undo")] }

    # A spec tool rather than the real `undo_chore_completion`, because
    # `Buddy::Tools.register` writes to a registry the whole process shares.
    before {
      executed = @executed
      Buddy::Tools.register(
        name:        :spec_undo,
        summary:     "spec-only",
        description: "takes something away",
        args:        { tag: { type: :string, required: true } },
        confirm:     ->(p, _) { { summary: "Undo #{p[:tag]}?", resolved: {} } },
        label:       ->(p, _) { p[:tag].to_s },
        execute:     ->(p, _) { executed << p[:tag]; { echoed: p[:tag] } },
        receipt:     ->(r, _) { "Undid #{r[:echoed]}" },
      )
      stub_const("Buddy::ProposalExecutor::UNDOING_TOOLS", Set["spec_undo"])
    }

    def run_all(buttons)
      action = action_with(buttons, decision: { "value" => buttons.pluck("id") })
      described_class.perform(action.id)
      action.reload
    end

    it "settles the removal first however the model listed them, leaving the rows drawn as proposed", :aggregate_failures do
      action = run_all(pair)
      expect(@executed).to eq(["undo", "create"])
      expect(action.buttons.pluck("id")).to eq([1, 2])

      @executed.clear
      run_all(pair.reverse)
      expect(@executed).to eq(["undo", "create"])
    end

    # `sort_by` is not stable, so rows that tie carry the model's own order in
    # as the tiebreak.
    it "keeps rows that neither remove anything in the order they came" do
      run_all(%w[A B C D].each_with_index.map { |tag, i| row(i + 1, tag) })

      expect(@executed).to eq(%w[A B C D])
    end
  end
end
