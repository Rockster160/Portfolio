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
  let(:conversation) { user.byte_conversations.create!(mode: :buddy) }
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
      ctx = described_class.build(user, conversation)

      pending_names = ctx[:chores_pending_today].map { |c| c[:name] }
      done_names    = ctx[:chores_done_today].map { |c| c[:name] }

      expect(pending_names).to include("Water plants")
      expect(pending_names).not_to include("Brush teeth")
      expect(done_names).to include("Brush teeth")
      expect(done_names).not_to include("Water plants")
    end

    it "populates the identity + time fields" do
      ctx = described_class.build(user, conversation)

      expect(ctx[:user_first_name]).to be_present
      expect(ctx[:timezone]).to eq("America/Denver")
      expect(ctx[:now_local]).to be_present
    end

    # Canary: silent-rescue detector. Every Buddy rescue funnels through
    # Buddy::Errors.report. This spec asserts .report is never called
    # during a healthy build - catches the WHOLE class of bug (typos,
    # renamed methods, API drift) at commit time. Includes rescues in
    # Context and any other builder called during Context.build.
    it "never invokes Buddy::Errors.report during a healthy build" do
      allow(Buddy::Errors).to receive(:report).and_call_original

      described_class.build(user, conversation)

      expect(Buddy::Errors).not_to have_received(:report)
    end
  end

  # Prod 3129 and 3208: told it hadn't done a thing, Buddy argued and was wrong
  # both times. The receipts are kept out of the transcript on purpose, so this
  # is the only record of its own doing it can consult.
  describe "recent_actions" do
    def chip(body, at:, tool: "call_jil_function", ok: true)
      conversation.byte_messages.create!(
        user:       user,
        direction:  :inbound,
        state:      :delivered,
        body:       body,
        created_at: at,
        metadata:   { "kind" => "buddy_activity", "tool_name" => tool, "ok" => ok },
      )
    end

    it "reports what ran, newest first, with the tool that ran it" do
      chip("Called **HASS Blinds**", at: 20.minutes.ago)
      chip("Dark monitors", at: 2.minutes.ago, tool: "mac_command")

      actions = described_class.build(user, conversation)[:recent_actions]

      expect(actions.pluck(:did)).to eq(["Dark monitors", "Called HASS Blinds"])
      expect(actions.first[:tool]).to eq("mac_command")
      expect(actions.first[:at]).to be_present
    end

    it "leaves out prose, so only things that really ran are evidence" do
      conversation.byte_messages.create!(
        user: user, direction: :inbound, state: :delivered,
        body: "Kk! Monitors are out. *click*", metadata: { "kind" => "buddy" }
      )

      expect(described_class.build(user, conversation)[:recent_actions]).to be_empty
    end

    it "does not reach back past the window, so it answers 'did you just'" do
      chip("Called **HASS Light**", at: 5.hours.ago)

      expect(described_class.build(user, conversation)[:recent_actions]).to be_empty
    end

    it "keeps a failed call, which is its own answer" do
      chip("Called **HASS TV**", at: 1.minute.ago, ok: false)

      expect(described_class.build(user, conversation)[:recent_actions].first[:ok]).to be(false)
    end

    it "is nameable through get_context, or Buddy can never ask for it" do
      expect(Buddy::GPT::ContextTool::SECTIONS).to include(:recent_actions)
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
