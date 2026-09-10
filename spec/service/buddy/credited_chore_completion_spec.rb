require "rails_helper"

# Marking a chore done on behalf of somebody else in the house. The credit has
# to land on THEM - pebbles, streak, their card - while the row still records
# who actually pressed it, because that is what keeps the recorder's own
# automations firing (see ChoreCompletion#trigger_target_users).
RSpec.describe "Buddy credited chore completion" do
  let(:recorder) { create(:user, username: "rowan") }
  let(:housemate) { create(:user, username: "wren") }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: recorder) }
  let!(:chore) { household.chores.create!(created_by_user: recorder, name: "Recycling", reward_pebbles: 2) }

  before do
    recorder.update!(chore_household_id: household.id)
    housemate.update!(chore_household_id: household.id)
    ChoreHouseholdMembership.create!(chore_household: household, user: housemate, role: :member)
    allow(::Jil).to receive(:trigger)
    allow(ChoreBroadcaster).to receive(:broadcast_changes!)
  end

  def run(payload, user: recorder)
    tool     = Buddy::Tools[:complete_chore]
    confirm  = tool[:confirm].call(payload, Buddy::ToolContext.new(user))
    resolved = payload.merge(confirm[:resolved])
    result   = tool[:execute].call(resolved, Buddy::ToolContext.new(user))
    [result, resolved, confirm, tool]
  end

  it "credits the housemate and records who marked it" do
    result, resolved, confirm = run({ chore: "Recycling", credit_to: "wren" })
    completion = ChoreCompletion.find(result[:chore_completion_id])

    expect(resolved[:credit_user_id]).to eq(housemate.id)
    expect(confirm[:summary]).to include("for wren")
    expect(completion.user).to eq(housemate)
    expect(completion.recorded_by_user).to eq(recorder)
    expect(completion.anonymous).to be(false)
  end

  it "pays the housemate rather than the person who spoke" do
    expect { run({ chore: "Recycling", credit_to: "wren" }) }
      .to change { housemate.reload.chore_completions.sum(:paid_pebbles) }.by(2)
    expect(recorder.reload.chore_completions.count).to eq(0)
  end

  it "leaves an ordinary completion untouched" do
    result, resolved = run({ chore: "Recycling" })
    completion = ChoreCompletion.find(result[:chore_completion_id])

    expect(resolved).not_to have_key(:credit_user_id)
    expect(completion.user).to eq(recorder)
    expect(completion.recorded_by_user).to be_nil
  end

  it "treats crediting yourself as an ordinary completion" do
    result, resolved = run({ chore: "Recycling", credit_to: "rowan" })
    completion = ChoreCompletion.find(result[:chore_completion_id])

    expect(resolved).not_to have_key(:credit_user_id)
    expect(completion.recorded_by_user).to be_nil
  end

  it "refuses a name nobody in the house goes by" do
    expect { run({ chore: "Recycling", credit_to: "Marguerite" }) }
      .to raise_error(/nobody in the house/)
  end

  it "records against the credited person's own half of a split chore" do
    mine = household.chores.create!(
      created_by_user: recorder, name: "Teeth (mine)", parent_chore: chore, assigned_to_user: recorder,
    )
    theirs = household.chores.create!(
      created_by_user: recorder, name: "Teeth (theirs)", parent_chore: chore, assigned_to_user: housemate,
    )
    result, = run({ chore: "Recycling", credit_to: "wren" })

    expect(ChoreCompletion.find(result[:chore_completion_id]).chore).to eq(theirs)
    expect(mine.chore_completions.count).to eq(0)
  end

  it "tells the recorder's own devices as well as the credited person's" do
    run({ chore: "Recycling", credit_to: "wren" })

    expect(ChoreBroadcaster).to have_received(:broadcast_changes!).with(housemate, anything, anything)
    expect(ChoreBroadcaster).to have_received(:broadcast_changes!).with(recorder, anything, anything)
  end

  it "names the credited person on the row and in the receipt" do
    _result, resolved, _confirm, tool = run({ chore: "Recycling", credit_to: "wren" })
    label = tool[:label].call(resolved, Buddy::ToolContext.new(recorder))
    ctx   = Buddy::ToolContext.new(recorder)
    allow(ctx).to receive(:proposal).and_return({ "payload" => resolved.stringify_keys })

    expect(label[:sub]).to include("credited to wren")
    expect(tool[:receipt].call({}, ctx)).to include("for wren")
  end

  describe "undoing one" do
    before { allow(ChoreStreak).to receive(:rebuild_for!) }

    it "rebuilds the credited person's streak, not the actor's" do
      result, = run({ chore: "Recycling", credit_to: "wren" })
      completion = ChoreCompletion.find(result[:chore_completion_id])

      ChoreCompletionUndoer.call(recorder, completion)

      expect(ChoreStreak).to have_received(:rebuild_for!).with(housemate, chore)
      expect(ChoreStreak).not_to have_received(:rebuild_for!).with(recorder, chore)
    end
  end

  it "can still be reached by the person who recorded it" do
    result, = run({ chore: "Recycling", credit_to: "wren" })
    found = Buddy::ToolContext.new(recorder).resolve_chore_completion("Recycling")

    expect(found&.id).to eq(result[:chore_completion_id])
  end
end
