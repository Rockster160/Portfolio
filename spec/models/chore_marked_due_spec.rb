require "rails_helper"

RSpec.describe Chore, "marked_due" do
  let(:user) { create(:user) }
  let(:chore) { create(:chore, created_by_user: user) }

  describe "#marked_due?" do
    it "is false when marked_due_at is nil" do
      expect(chore.marked_due?).to be(false)
    end

    it "is true when marked_due_at is present" do
      chore.update!(marked_due_at: Time.current)
      expect(chore.marked_due?).to be(true)
    end
  end

  describe "ChoreCompletion clears the stamp" do
    before { chore.update!(marked_due_at: 2.hours.ago) }

    it "clears on a credited completion" do
      create(:chore_completion, chore: chore, user: user)
      expect(chore.reload.marked_due_at).to be_nil
    end

    it "clears on a skipped completion" do
      create(:chore_completion, chore: chore, user: user, payout_skipped: true)
      expect(chore.reload.marked_due_at).to be_nil
    end

    it "clears on an anonymous completion (household member can clear without credit)" do
      create(:chore_completion, chore: chore, user: user, anonymous: true)
      expect(chore.reload.marked_due_at).to be_nil
    end

    it "bumps updated_at so /chores/sync picks up the change" do
      original_updated = chore.updated_at
      travel_to(1.minute.from_now) do
        create(:chore_completion, chore: chore, user: user)
      end
      expect(chore.reload.updated_at).to be > original_updated
    end

    it "no-ops when nothing was stamped (avoids needless write)" do
      chore.update!(marked_due_at: nil)
      original_updated = chore.updated_at
      travel_to(1.minute.from_now) do
        create(:chore_completion, chore: chore, user: user)
      end
      expect(chore.reload.updated_at).to eq(original_updated)
    end
  end
end
