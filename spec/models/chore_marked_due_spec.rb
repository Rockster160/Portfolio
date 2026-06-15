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

  describe "ChoreCompletion does NOT clear the stamp synchronously" do
    # The mark stays until ChoreDailyResetWorker runs at the next
    # chore-day rollover. Holding the clear keeps today_visible? /
    # scheduled_due_on stable across same-day completions — completing
    # a chore must not change its slot in the Today tab.
    before { chore.update!(marked_due_at: 2.hours.ago) }

    it "keeps marked_due_at intact after a credited completion" do
      create(:chore_completion, chore: chore, user: user)
      expect(chore.reload.marked_due_at).to be_present
    end

    it "keeps marked_due_at intact after a skipped completion" do
      create(:chore_completion, chore: chore, user: user, payout_skipped: true)
      expect(chore.reload.marked_due_at).to be_present
    end

    it "keeps marked_due_at intact after an anonymous completion" do
      create(:chore_completion, chore: chore, user: user, anonymous: true)
      expect(chore.reload.marked_due_at).to be_present
    end
  end
end
