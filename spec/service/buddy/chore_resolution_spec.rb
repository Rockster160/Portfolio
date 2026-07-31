require "rails_helper"

# Which chore a fuzzy name lands on. This matters more than most resolvers
# because complete_chore runs the instant it resolves — a wrong match doesn't
# ask, it writes a completion for something nobody did.
RSpec.describe "Buddy chore resolution" do
  let(:user)       { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let(:ctx)        { Buddy::ToolContext.new(user) }

  def chore!(name)
    create(:chore, created_by_user: user, chore_household: household, name: name)
  end

  it "takes an exact name over anything else" do
    chore!("Water plants")
    exact = chore!("Water")

    expect(ctx.resolve_chore("water")).to eq(exact)
  end

  # Prod 1357-1363: "water" matched both "Wash Water Bowls" (id 5) and "8oz
  # Water" (id 9), enumeration order picked the lower id, and someone logging
  # that they drank something got three bowl-washings marked off.
  describe "when several names contain what they said" do
    it "picks the one the word is mostly ABOUT, not the one that mentions it" do
      chore!("Wash Water Bowls")
      drink = chore!("8oz Water")

      expect(ctx.resolve_chore("water")).to eq(drink)
    end

    it "doesn't depend on which was created first" do
      drink = chore!("8oz Water")
      chore!("Wash Water Bowls")

      expect(ctx.resolve_chore("water")).to eq(drink)
    end

    it "still finds the long name when that's what they typed" do
      bowls = chore!("Wash Water Bowls")
      chore!("8oz Water")

      expect(ctx.resolve_chore("wash water bowls")).to eq(bowls)
    end
  end

  describe "when nothing contains it" do
    it "forgives a typo" do
      brush = chore!("Brush Teeth")

      expect(ctx.resolve_chore("brush teth")).to eq(brush)
    end

    # "waters" used to come back "Shower" — five edits away, and simply the
    # least-bad of a field that had nothing in it. Resolving to nothing raises,
    # which makes Buddy ask instead of act.
    it "gives up rather than handing back the closest of a bad field" do
      chore!("Shower")
      chore!("Feed Byte")

      expect(ctx.resolve_chore("waters")).to be_nil
    end

    it "gives up on a word with no relation to anything" do
      chore!("Brush Teeth")

      expect(ctx.resolve_chore("helicopter")).to be_nil
    end
  end

  it "returns nothing for a blank name" do
    chore!("Brush Teeth")

    expect(ctx.resolve_chore("")).to be_nil
    expect(ctx.resolve_chore(nil)).to be_nil
  end
end
