require "rails_helper"

# Personal chores credit only the person who did them; household chores count
# if ANYONE did them. The bug: Chelsea brushing her teeth showed as Rocco's
# teeth already done.
RSpec.describe Buddy::Context, ".build chore attribution" do
  let(:household) { create(:chore_household) }
  let(:rocco)     { create(:user) }
  let(:chelsea)   { create(:user) }
  let(:conversation) { rocco.byte_conversations.create!(mode: :buddy) }

  before do
    ChoreHouseholdMembership.create!(chore_household: household, user: rocco,   role: :manager)
    ChoreHouseholdMembership.create!(chore_household: household, user: chelsea, role: :manager)
    rocco.update_column(:chore_household_id, household.id)
    chelsea.update_column(:chore_household_id, household.id)
  end

  it "does not credit a PERSONAL chore to Rocco when Chelsea did it, but DOES for a household one" do
    teeth = create(:chore, name: "Brush Teeth", chore_household: household, created_by_user: rocco, sharing_mode: :personal)
    feed  = create(:chore, name: "Feed Whisper", chore_household: household, created_by_user: rocco, sharing_mode: :household)
    ChoreDaily.create!(user: rocco, chore: teeth)
    ChoreDaily.create!(user: rocco, chore: feed)

    # Chelsea completes both today.
    create(:chore_completion, chore: teeth, user: chelsea, day_key: rocco.perceived_today)
    create(:chore_completion, chore: feed,  user: chelsea, day_key: rocco.perceived_today)

    ctx     = described_class.build(rocco, conversation)
    pending = ctx[:chores_pending_today].map { |c| c[:name] }
    done    = ctx[:chores_done_today].map { |c| c[:name] }

    expect(pending).to include("Brush Teeth")     # personal → Chelsea's doesn't count for Rocco
    expect(done).not_to include("Brush Teeth")
    expect(done).to include("Feed Whisper")       # household → anyone counts
  end

  it "credits a personal chore to Rocco when ROCCO did it" do
    teeth = create(:chore, name: "Brush Teeth", chore_household: household, created_by_user: rocco, sharing_mode: :personal)
    ChoreDaily.create!(user: rocco, chore: teeth)
    create(:chore_completion, chore: teeth, user: rocco, day_key: rocco.perceived_today)

    ctx = described_class.build(rocco, conversation)
    expect(ctx[:chores_done_today].map { |c| c[:name] }).to include("Brush Teeth")
  end
end
