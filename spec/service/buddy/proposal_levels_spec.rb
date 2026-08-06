require "rails_helper"

# The three confidence levels: level 1 fires + receipt chip (no checkbox),
# level 2 fires immediately as a PRE-CHECKED undoable row, level 3 waits for a
# tap. This covers level 2 (the new behavior) and the level-2/3 split.
RSpec.describe "Buddy proposal levels" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let!(:message) {
    convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hi", metadata: { "kind" => "buddy" })
  }

  before do
    user.update!(chore_household_id: household.id)
    allow(MonitorChannel).to receive(:broadcast_to)
  end

  def build(markers)
    Buddy::ProposalBuilder.create(user: user, byte_message: message.reload, markers: markers)
  end

  it "runs a level-2 tool immediately and marks the row executed + undoable" do
    result = build([{ tool_name: :log_event, payload: { name: "Coffee" } }])
    btn = result[:action].buttons.first

    expect(btn["status"]).to eq("executed")
    expect(btn["undoable"]).to be(true)
    expect(ActionEvent.where(user: user, name: "Coffee")).to exist
  end

  # A log is a record of the past. Prod: "I picked up lunch so I'm planning on
  # sitting down to eat it" was written into the history as a completed Lunch,
  # which is a fact in their record that never happened.
  it "tells the model a log is for what already happened, not what they're about to do" do
    description = Buddy::Tools[:log_event][:description]

    expect(description).to include("ONLY for something that ALREADY HAPPENED")
    expect(description).to include("I'm about to have lunch")
    expect(description).to include("The moment they say they DID it, log it then")
  end

  it "undoes a level-2 row when it's unchecked" do
    action = build([{ tool_name: :log_event, payload: { name: "Tea" } }])[:action]
    id = action.buttons.first["id"]

    Buddy::ProposalExecutor.undo!(action.id, id)

    expect(action.reload.buttons.first["status"]).to eq("undone")
    expect(ActionEvent.where(user: user, name: "Tea")).not_to exist
  end

  it "executes level-2 rows but leaves level-3 rows pending in the same checklist" do
    logged = ActionEvent.create!(user: user, name: "Coffee", timestamp: Time.current)
    result = build([
      { tool_name: :log_event,  payload: { name: "Water" } },                        # level 2
      { tool_name: :edit_event, payload: { event: "Coffee", name: "Decaf" } },       # level 3
    ])
    by_tool = result[:action].buttons.index_by { |b| b["tool_name"] }

    expect(by_tool["log_event"]["status"]).to eq("executed")
    expect(by_tool["edit_event"]["status"]).to eq("pending")
    # The level-3 rename has NOT happened yet — it waits for a tap.
    expect(logged.reload.name).to eq("Coffee")
  end

  # Prod message 1134: "Turn the fan to high, please" -> "Done. Fan's on high
  # now." and NOTHING else. The task really fired, but the receipt read
  # `ctx.proposal["payload"]`, and run_auto built a context without a proposal,
  # so it raised NoMethodError on nil, got swallowed, and the chip was skipped.
  # A level-1 action leaves no checklist row, so that prose was the only trace -
  # and prose is the one thing we can't take at face value.
  describe "the activity chip a level-1 action leaves behind" do
    let!(:fan) {
      Task.create!(
        user:          user,
        name:          "Fan High",
        listener:      "fan-high",
        code:          "// noop",
        enabled:       true,
        buddy_enabled: true,
        description:   "Sets the great room fan to high",
      )
    }

    def chip
      convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
    end

    before { allow(::Jil).to receive(:trigger) }

    it "posts a chip naming the tool and the params it ran with" do
      result = build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

      expect(result[:auto_ran]).to be(true)
      expect(chip).to be_present
      # Receipt in the body; which tool and which args as a separate footnote,
      # so the two can be styled apart instead of running together.
      expect(chip.body).to eq("Fired **Fan High**")
      expect(chip.metadata["detail"]).to eq("scope: fan-high")
      expect(chip.metadata["tool_name"]).to eq("trigger_jil_task")
    end

    # CSS puts a ✓ in front of every chip, and most receipts end with one of
    # their own - together they rendered "✓ Fired Fan High ✓".
    it "does not leave a second checkmark on the end of the receipt" do
      build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

      expect(chip.body).not_to end_with("✓")
    end

    it "records the exact arguments on the chip for later inspection" do
      build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

      expect(chip.metadata["tool_name"]).to eq("trigger_jil_task")
      expect(chip.metadata["payload"]).to include("task_name" => "Fan High", "scope" => "fan-high")
    end

    it "still posts a chip when the receipt itself blows up" do
      allow(Buddy::Tools[:trigger_jil_task][:receipt]).to receive(:call).and_raise("receipt exploded")

      build([{ tool_name: :trigger_jil_task, payload: { name: "Fan High" } }])

      expect(chip).to be_present
      expect(chip.metadata["tool_name"]).to eq("trigger_jil_task")
    end

    # list_reminders returns nil on purpose: the rows it draws in the thread ARE
    # the output, so a chip would just sit above them saying it drew them. That
    # opt-out has to keep working.
    it "still honors a deliberate nil-receipt opt-out" do
      build([{ tool_name: :list_reminders, payload: {} }])

      expect(chip).to be_nil
    end
  end

  it "tiers are assigned as expected on the registry" do
    expect(Buddy::Tools[:log_event][:level]).to eq(2)
    expect(Buddy::Tools[:complete_chore][:level]).to eq(2)
    expect(Buddy::Tools[:add_list_item][:level]).to eq(2)
    expect(Buddy::Tools[:call_jil_function][:level]).to eq(1)
    expect(Buddy::Tools[:call_jil_function][:auto]).to be(true)
    expect(Buddy::Tools[:edit_event][:level]).to eq(3)
  end

  # Writing to a chore or a calendar runs on arrival and unticks back off. They
  # were level 3 and made you confirm every one, which was a toll on the common
  # case: you'd already said what you wanted, and both are visible and easy to
  # take back.
  it "runs chore and agenda writes without asking first" do
    %i[create_chore edit_chore add_agenda_item edit_agenda_item].each { |name|
      expect(Buddy::Tools[name][:level]).to eq(2), "#{name} should run on arrival"
    }
  end

  # A level-2 row promises an undo, and the row is a lie without one. Every one
  # of these has to hand back a descriptor the Reverter recognises.
  it "keeps every level-2 tool on a model the Reverter can walk back" do
    levelled = Buddy::Tools.all.select { |t| t[:level] == 2 }

    expect(levelled).to be_present
    expect(levelled.pluck(:name)).to include(:create_chore, :edit_chore, :add_agenda_item, :edit_agenda_item)
    expect(Buddy::Reverter::MODELS).to include("Chore", "AgendaItem")
  end
end
