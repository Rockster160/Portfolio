require "rails_helper"

RSpec.describe "Chore + ChoreCompletion Jil triggers", type: :model do
  describe "chore + completion" do
    let(:user) { create(:user) }

    it "creating a chore fires `chore` trigger with action: :created" do
      expect(::Jil).to receive(:trigger).with(
        user, :chore, satisfy { |attrs| attrs[:action] == :created && attrs[:name] == "Vacuum" }
      )
      create(:chore, created_by_user: user, name: "Vacuum")
    end

    it "updating a chore fires action: :updated" do
      chore = create(:chore, created_by_user: user, name: "V")
      expect(::Jil).to receive(:trigger).with(
        user, :chore, satisfy { |attrs| attrs[:action] == :updated }
      )
      chore.update!(name: "Vacuum")
    end

    it "stamping marked_due_at fires action: :marked_due (not :updated)" do
      chore = create(:chore, created_by_user: user, name: "V")
      expect(::Jil).to receive(:trigger).with(
        user, :chore, satisfy { |attrs| attrs[:action] == :marked_due && attrs[:name] == "V" }
      )
      chore.update!(marked_due_at: Time.current)
    end

    it "clearing marked_due_at via user update fires action: :unmarked_due" do
      chore = create(:chore, created_by_user: user, name: "V", marked_due_at: 1.hour.ago)
      expect(::Jil).to receive(:trigger).with(
        user, :chore, satisfy { |attrs| attrs[:action] == :unmarked_due }
      )
      chore.update!(marked_due_at: nil)
    end

    it "completion does NOT fire :unmarked_due (mark is held until daily reset)" do
      chore = create(:chore, created_by_user: user, name: "V", marked_due_at: 1.hour.ago)
      # The completion fires its own :chore_completion :completed trigger.
      # The mark is held until the next-day rollover (ChoreDailyResetWorker),
      # which clears it without firing a Jil trigger — a system cleanup
      # is not the same as a user-driven unmark.
      allow(::Jil).to receive(:trigger)
      expect(::Jil).not_to receive(:trigger).with(
        user, :chore, satisfy { |attrs| attrs[:action] == :unmarked_due }
      )
      create(:chore_completion, chore: chore, user: user)
    end

    it "archiving a chore (archived_at flip) fires action: :archived" do
      chore = create(:chore, created_by_user: user, name: "V")
      expect(::Jil).to receive(:trigger).with(
        user, :chore, satisfy { |attrs| attrs[:action] == :archived }
      )
      chore.update!(archived_at: Time.current)
    end

    it "destroying a chore fires action: :destroyed" do
      chore = create(:chore, created_by_user: user, name: "V")
      expect(::Jil).to receive(:trigger).with(
        user, :chore, satisfy { |attrs| attrs[:action] == :destroyed }
      )
      chore.destroy!
    end

    it "creating a completion fires `chore_completion` action: :completed" do
      chore = create(:chore, created_by_user: user, name: "Walk", reward_pebbles: 4)
      expect(::Jil).to receive(:trigger).with(
        user, :chore_completion,
        satisfy { |a| a[:action] == :completed && a[:chore_name] == "Walk" && a[:paid_pebbles] == 4 }
      )
      ChoreCompleter.new(chore, user).call
    end

    it "destroying a completion fires `chore_completion` action: :uncompleted" do
      chore = create(:chore, created_by_user: user, name: "Walk")
      completion = ChoreCompleter.new(chore, user).call.completion
      expect(::Jil).to receive(:trigger).with(
        user, :chore_completion,
        satisfy { |a| a[:action] == :uncompleted && a[:chore_name] == "Walk" }
      )
      completion.destroy!
    end

    it "creating a withdrawal fires `chore_withdrawal` action: :created" do
      expect(::Jil).to receive(:trigger).with(
        user, :chore_withdrawal,
        satisfy { |a| a[:action] == :created && a[:amount_pebbles] == 5 && a[:note] == "snack" }
      )
      create(:chore_withdrawal, user: user, amount_pebbles: 5, note: "snack")
    end

    it "updating + destroying a withdrawal fires :updated / :destroyed" do
      withdrawal = create(:chore_withdrawal, user: user, amount_pebbles: 5)
      expect(::Jil).to receive(:trigger).with(
        user, :chore_withdrawal, satisfy { |a| a[:action] == :updated }
      )
      withdrawal.update!(amount_pebbles: 6)
      expect(::Jil).to receive(:trigger).with(
        user, :chore_withdrawal, satisfy { |a| a[:action] == :destroyed }
      )
      withdrawal.destroy!
    end

    it "creating a transfer fires `chore_transfer` for BOTH endpoints with direction set" do
      sender = create(:user)
      recipient = create(:user)
      share_chore_household!(sender, recipient)
      chore = create(:chore, created_by_user: sender, reward_pebbles: 50)
      create(
        :chore_completion, chore: chore, user: sender, paid_pebbles: 50, base_pebbles: 50,
        payout_skipped: false, day_key: ChoreDay.current(sender) - 1
      )
      expect(::Jil).to receive(:trigger).with(
        sender, :chore_transfer,
        satisfy { |a| a[:action] == :created && a[:direction] == :outgoing && a[:counterparty_username] == recipient.username }
      )
      expect(::Jil).to receive(:trigger).with(
        recipient, :chore_transfer,
        satisfy { |a| a[:action] == :created && a[:direction] == :incoming && a[:counterparty_username] == sender.username }
      )
      ChoreTransfer.create!(from_user: sender, to_user: recipient, amount_pebbles: 10)
    end
  end

  describe "completion lifecycle" do
    let(:user) { User.me }
    let!(:chore) { Chore.create!(name: "Wordle", created_by_user_id: user.id, reward_pebbles: 5) }

    let(:fired) { [] }

    before {
      allow(::Jil).to receive(:trigger) { |target, scope, payload, **|
        fired << [target, scope, payload.execution_attrs]
      }
    }

    it "fires :completed on create with jil_attrs payload" do
      chore.chore_completions.create!(
        user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
      )

      _target, scope, attrs = fired.first
      expect(scope).to eq(:chore_completion)
      expect(attrs[:action]).to eq(:completed)
      expect(attrs[:chore_name]).to eq("Wordle")
      expect(attrs[:completed_by_user_id]).to eq(user.id)
      expect(attrs[:completed_by_username]).to eq(user.username)
    end

    it "fires ONLY :completed on create (no :edited double-fire from after_update_commit)" do
      chore.chore_completions.create!(
        user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
      )

      actions = fired.map { |_target, _scope, attrs| attrs[:action] }
      expect(actions).to eq([:completed])
    end

    it "fires :edited on update with saved_changes included" do
      completion = chore.chore_completions.create!(
        user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
      )
      fired.clear

      new_at = 1.hour.ago
      completion.update!(completed_at: new_at)

      expect(fired.length).to eq(1)
      _target, scope, attrs = fired.first
      expect(scope).to eq(:chore_completion)
      expect(attrs[:action]).to eq(:edited)
      expect(attrs[:changes]).to be_a(Hash)
      expect(attrs[:changes]["completed_at"]).to be_an(Array)
      expect(attrs[:changes]["completed_at"].last).to be_within(1.second).of(new_at)
    end

    it "does NOT fire :edited when nothing changed (touch-only save short-circuit)" do
      completion = chore.chore_completions.create!(
        user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
      )
      fired.clear

      completion.save! # no attribute changes

      expect(fired).to be_empty
    end

    it "fires :uncompleted on destroy" do
      completion = chore.chore_completions.create!(
        user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
      )
      fired.clear

      completion.destroy!

      _target, scope, attrs = fired.first
      expect(scope).to eq(:chore_completion)
      expect(attrs[:action]).to eq(:uncompleted)
    end

    describe "household fan-out" do
      let(:other) { create(:user) }
      let!(:household) { share_chore_household!(user, other) }
      let!(:shared_chore) {
        Chore.create!(
          name: "Take trash cans out", created_by_user_id: user.id,
          chore_household: household, sharing_mode: :household, reward_pebbles: 5,
        )
      }

      let(:completion_targets) {
        fired.select { |_target, scope, _attrs| scope == :chore_completion }.map { |target, _s, _a| target.id }
      }
      let(:completion_attrs) {
        _target, _scope, attrs = fired.find { |_target, scope, _attrs| scope == :chore_completion }
        attrs
      }

      it "fires the :completed trigger for every household member when a member completes a household chore" do
        shared_chore.chore_completions.create!(
          user: other, completed_at: Time.current, day_key: ChoreDay.current(other),
        )

        expect(completion_targets).to match_array(household.members.pluck(:id))
        expect(completion_attrs[:completed_by_user_id]).to eq(other.id)
        expect(completion_attrs[:completed_by_username]).to eq(other.username)
      end

      it "still fires only for the completing user on a personal chore" do
        personal = Chore.create!(
          name: "Wordle Solo", created_by_user_id: other.id,
          chore_household: household, sharing_mode: :personal, reward_pebbles: 5,
        )
        personal.chore_completions.create!(
          user: other, completed_at: Time.current, day_key: ChoreDay.current(other),
        )

        expect(completion_targets).to eq([other.id])
      end
    end
  end
end
