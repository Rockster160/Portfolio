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

  # A shared chore counts as done the moment anyone does it, which is right -
  # but the bucket carried no actor, so the whole thing read as a list of
  # Rocco's wins. Prod 2528 congratulated him for one he hadn't touched.
  describe "who gets the credit" do
    def feed_chore!
      create(
        :chore, name: "Feed Whisper", chore_household: household,
        created_by_user: rocco, sharing_mode: :household
      ).tap { |chore| ChoreDaily.create!(user: rocco, chore: chore) }
    end

    def done_row(name)
      described_class.build(rocco, conversation)[:chores_done_today].find { |c| c[:name] == name }
    end

    it "names the housemate who actually did it" do
      create(:chore_completion, chore: feed_chore!, user: chelsea, day_key: rocco.perceived_today)

      expect(done_row("Feed Whisper")[:by]).to eq(chelsea.first_name)
    end

    it "says nothing when Rocco did it himself" do
      create(:chore_completion, chore: feed_chore!, user: rocco, day_key: rocco.perceived_today)

      expect(done_row("Feed Whisper")).not_to have_key(:by)
    end

    # Both of them tapping it is a real thing that happens, and he did do it,
    # so the credit is his to take.
    it "says nothing when they both did it" do
      feed = feed_chore!
      create(:chore_completion, chore: feed, user: chelsea, day_key: rocco.perceived_today)
      create(:chore_completion, chore: feed, user: rocco, day_key: rocco.perceived_today)

      expect(done_row("Feed Whisper")).not_to have_key(:by)
    end

    it "leaves pending chores alone" do
      feed_chore!

      pending = described_class.build(rocco, conversation)[:chores_pending_today]
      expect(pending.find { |c| c[:name] == "Feed Whisper" }).not_to have_key(:by)
    end
  end
end
