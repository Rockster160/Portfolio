require "rails_helper"

# Two-layer defense against silent "empty context" regressions:
#   1. Explicit fixture setup exercises the FULL happy path against
#      Buddy::Context.build. Any method-name typo / API drift breaks
#      a specific assertion, same as the member_user_ids bug.
#   2. Canary spec: assert Rails.logger receives ZERO warnings during
#      a healthy build. Every silent rescue in Context.rb logs on
#      failure - if a future change adds a typo in ANY builder, its
#      rescue fires, its warning fires, this spec breaks. Catches the
#      pattern, not the specific bug.
RSpec.describe Buddy::Context do
  let!(:owner) { User.create!(username: "owner-#{SecureRandom.hex(4)}", password: "abcd1234!", password_confirmation: "abcd1234!") }
  let!(:household) {
    ChoreHousehold.create!(owner_user: owner, name: "Test HH").tap { |h|
      owner.update!(chore_household_id: h.id)
    }
  }
  let(:user) { owner.reload }
  let(:today) { user.perceived_today }

  # Two chores: one still-pending, one done today. Both dailies so
  # they land in chores_pending_today / chores_done_today.
  let!(:pending_chore) {
    Chore.create!(name: "Water plants", chore_household: household, created_by_user: owner, sharing_mode: :household, recurrence: { freq: "daily" })
  }
  let!(:done_chore) {
    Chore.create!(name: "Brush teeth", chore_household: household, created_by_user: owner, sharing_mode: :household, recurrence: { freq: "daily" })
  }
  before {
    ChoreDaily.create!(user: user, chore: pending_chore, sort_order: 0)
    ChoreDaily.create!(user: user, chore: done_chore,    sort_order: 1)
    ChoreCompletion.create!(
      user: user, chore: done_chore, completed_at: Time.current, day_key: today,
      paid_pebbles: 0, base_pebbles: 0, hot_multiplier: 1.0,
      achievement_bonus_pebbles: 0, payout_skipped: false,
    )
  }

  describe ".build (populated fixtures - end to end)" do
    it "returns pending and done chores split into their own buckets" do
      ctx = described_class.build(user)

      pending_names = ctx[:chores_pending_today].map { |c| c[:name] }
      done_names    = ctx[:chores_done_today].map { |c| c[:name] }

      expect(pending_names).to include("Water plants")
      expect(pending_names).not_to include("Brush teeth")
      expect(done_names).to include("Brush teeth")
      expect(done_names).not_to include("Water plants")
    end

    it "populates the identity + time fields" do
      ctx = described_class.build(user)

      expect(ctx[:user_first_name]).to be_present
      expect(ctx[:timezone]).to eq("America/Denver")
      expect(ctx[:now_local]).to be_present
    end

    # Canary: silent-rescue detector. Every Buddy rescue funnels through
    # Buddy::Errors.report. This spec asserts .report is never called
    # during a healthy build - catches the WHOLE class of bug (typos,
    # renamed methods, API drift) at commit time. Includes rescues in
    # Context, ContextSnapshot, and any other builder called during
    # Context.build.
    it "never invokes Buddy::Errors.report during a healthy build" do
      allow(Buddy::Errors).to receive(:report).and_call_original

      described_class.build(user)

      expect(Buddy::Errors).not_to have_received(:report)
    end
  end

  describe "member_user_ids regression guard" do
    it "calls a method that actually exists on ChoreHousehold" do
      expect(household).to respond_to(:member_user_ids)
      expect(household).not_to respond_to(:user_ids)
      expect(household.member_user_ids).to eq([owner.id])
    end
  end
end
