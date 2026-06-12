require "rails_helper"

RSpec.describe "ChoreGoals reopen", type: :request do
  let(:user) { create(:user) }
  let!(:chore) { create(:chore, created_by_user: user, reward_pebbles: 5) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def json = response.parsed_body

  describe "POST /chores/goals/:id/reopen" do
    it "clears achieved_at and stays open when conditions are no longer met" do
      goal = ChoreGoal.create!(
        user: user, name: "Saver", kind: :pebbles,
        scope_mode: :cumulative, tracking_mode: :saved, target_value: 10,
      )
      create(:chore_completion, user: user, chore: chore, paid_pebbles: 12)
      goal.refresh!
      expect(goal.reload.achieved_at).to be_present

      # User burns the balance back below target — goal would normally
      # stay locked. Reopen should let it drop back to outstanding.
      create(:chore_withdrawal, user: user, amount_pebbles: 50)

      post "/chores/goals/#{goal.id}/reopen"
      expect(response).to have_http_status(:ok)
      expect(goal.reload.achieved_at).to be_nil
      expect(json["achieved_at"]).to be_nil
    end

    it "re-locks immediately when the goal is still genuinely satisfied" do
      goal = ChoreGoal.create!(
        user: user, name: "Earner", kind: :pebbles,
        scope_mode: :cumulative, tracking_mode: :earned, target_value: 10,
      )
      create(:chore_completion, user: user, chore: chore, paid_pebbles: 25)
      goal.refresh!
      original = goal.reload.achieved_at
      expect(original).to be_present

      post "/chores/goals/#{goal.id}/reopen"
      expect(response).to have_http_status(:ok)
      reloaded = goal.reload.achieved_at
      expect(reloaded).to be_present
      expect(reloaded).to be > original
    end

    it "is a no-op (still allowed) on an already-outstanding goal" do
      goal = ChoreGoal.create!(
        user: user, name: "Future", kind: :pebbles,
        scope_mode: :cumulative, tracking_mode: :earned, target_value: 1000,
      )

      post "/chores/goals/#{goal.id}/reopen"
      expect(response).to have_http_status(:ok)
      expect(goal.reload.achieved_at).to be_nil
    end

    it "removes the awarded_pebbles bonus from balance when it drops back to outstanding" do
      goal = ChoreGoal.create!(
        user: user, name: "Bonus", kind: :pebbles,
        scope_mode: :cumulative, tracking_mode: :saved, target_value: 10,
        awarded_pebbles: 50,
      )
      create(:chore_completion, user: user, chore: chore, paid_pebbles: 12)
      goal.refresh!
      with_bonus = user.chore_balance
      create(:chore_withdrawal, user: user, amount_pebbles: 100)

      post "/chores/goals/#{goal.id}/reopen"
      expect(response).to have_http_status(:ok)
      expect(goal.reload.achieved_at).to be_nil
      # awarded_pebbles only counts via chore_goals.achieved — so dropping
      # the goal back to outstanding must remove its bonus from balance.
      expect(user.chore_balance).to eq(with_bonus - 100 - 50)
    end
  end
end
