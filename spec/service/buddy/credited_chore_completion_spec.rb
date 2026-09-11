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
    # Buddy::GPT::Turn asks this between resolving and running, and it is the
    # only thing standing between a clarification and a duplicate row.
    tool[:guard]&.call(resolved, Buddy::ToolContext.new(user))
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
  # Prod 5879: "Chelsea also did the gather versions for both" was a sentence
  # saying WHICH pair had been hers, and it got read as fresh work. Two
  # completions already written two minutes earlier were written again.
  # `merge_key` settles this within one card and cannot see the card above it.
  describe "recording the same one twice" do
    it "refuses a second completion for the same person on the same day" do
      run({ chore: "Recycling", credit_to: "wren" })

      expect { run({ chore: "Recycling", credit_to: "wren" }) }
        .to raise_error(/already marked done for wren/)
      expect(chore.chore_completions.count).to eq(1)
    end

    it "points at the tools that change one instead" do
      run({ chore: "Recycling" })

      expect { run({ chore: "Recycling" }) }
        .to raise_error(/edit_chore_completion.*undo_chore_completion/m)
    end

    # Two people doing the same chore is two rows, and always was - the
    # duplicate is per PERSON.
    it "lets a housemate do the one the recorder already did" do
      run({ chore: "Recycling" })

      expect { run({ chore: "Recycling", credit_to: "wren" }) }.not_to raise_error
      expect(chore.chore_completions.count).to eq(2)
    end

    # The day the row would LAND on, not today - so backdating one to a day
    # that is already covered is caught, and backdating to a free one isn't.
    it "reads the backdated day rather than the clock" do
      yesterday = (Time.current - 1.day).change(hour: 14).iso8601

      run({ chore: "Recycling", at: yesterday, credit_to: "wren" })

      expect { run({ chore: "Recycling", at: yesterday, credit_to: "wren" }) }
        .to raise_error(/already marked done/)
      expect { run({ chore: "Recycling", credit_to: "wren" }) }.not_to raise_error
    end

    # A chore meant to be done several times a day says so, and for those a
    # second row IS the point.
    it "leaves a chore with a daily target alone" do
      water = household.chores.create!(created_by_user: recorder, name: "Water", target_count: 4)
      run({ chore: "Water" })

      expect { run({ chore: "Water" }) }.not_to raise_error
      expect(water.chore_completions.count).to eq(2)
    end
  end
end
