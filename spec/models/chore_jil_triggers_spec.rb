require "rails_helper"

RSpec.describe "Chore + ChoreCompletion Jil triggers", type: :model do
  describe "chore + completion" do
    let(:user) { create(:user) }

    # A completion fires its own :chore_completion trigger; the mark it leaves
    # is cleared at the next-day rollover without firing :unmarked_due.
    it "fires `chore` with the action each lifecycle write stands for" do
      fired = []
      allow(::Jil).to receive(:trigger) { |_u, scope, payload, **|
        fired << [payload[:action], payload[:name]] if scope == :chore
      }

      chore = create(:chore, created_by_user: user, name: "V")
      chore.update!(name: "Vacuum")
      chore.update!(marked_due_at: Time.current)
      create(:chore_completion, chore: chore, user: user)
      chore.update!(marked_due_at: nil)
      chore.update!(archived_at: Time.current)
      chore.destroy!

      expect(fired.map(&:first)).to eq(%i[created updated marked_due unmarked_due archived destroyed])
      expect(fired.first.last).to eq("V")
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

    it "fires ONLY :completed on create, carrying who completed it" do
      chore.chore_completions.create!(
        user: user, completed_at: Time.current, day_key: ChoreDay.current(user),
      )

      expect(fired.map { |_t, _s, attrs| attrs[:action] }).to eq([:completed])
      _target, scope, attrs = fired.first
      expect(scope).to eq(:chore_completion)
      expect(attrs[:chore_name]).to eq("Wordle")
      expect(attrs[:completed_by_user_id]).to eq(user.id)
      expect(attrs[:completed_by_username]).to eq(user.username)
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

      # Crediting somebody must not hand them your automations: the credited
      # user and the recorder both hear about it, and the credit stays theirs.
      describe "a personal chore marked done on somebody else's behalf" do
        let!(:personal) {
          Chore.create!(
            name: "Pickup RX", created_by_user_id: user.id,
            chore_household: household, sharing_mode: :personal, reward_pebbles: 5,
          )
        }

        it "fires for the credited user and the recorder only, saying who did which", :aggregate_failures do
          third = create(:user, chore_household: household)

          completion = ChoreCompleter.new(personal, other, at: Time.current, recorded_by: user).call.completion

          expect(completion_targets).to match_array([other.id, user.id])
          expect(completion_targets).not_to include(third.id)
          expect(completion_attrs).to include(
            completed_by_user_id: other.id, completed_by_username: other.username,
            recorded_by_user_id: user.id, recorded_by_username: user.username,
            credited_to_other: true,
          )
          expect(completion.user_id).to eq(other.id)
          expect(completion.recorded_by_user_id).to eq(user.id)
          expect(completion.paid_pebbles).to be > 0
        end

        it "reads the recorder off an ordinary tap without storing a second copy" do
          completion = ChoreCompleter.new(personal, other, at: Time.current, recorded_by: other).call.completion

          expect(completion.recorded_by_user_id).to be_nil
          expect(completion.recorder).to eq(other)
          expect(completion).not_to be_credited_to_other
          expect(completion_targets).to eq([other.id])
        end
      end
    end
  end
end
