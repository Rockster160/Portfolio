require "rails_helper"

# The anonymous-completion endpoint doubles as "complete on behalf of a
# household member": when `credit_user_id` is present and belongs to the
# recorder's household, the full ChoreCompleter pipeline runs under that
# user's name (points, streak, Jil trigger). When it's blank or foreign,
# the original anonymous flow runs.
RSpec.describe "ChoreCompletions credit_user_id", type: :request do
  let(:owner) { create(:user) }
  # Owner-user gets a manager membership automatically via the household model.
  let(:household) { create(:chore_household, owner_user: owner) }
  let(:member) { create(:user) }
  let!(:member_membership) { create(:chore_household_membership, chore_household: household, user: member, role: :member) }
  let(:outsider) { create(:user) }
  let(:chore) { create(:chore, created_by_user: owner, chore_household: household, reward_pebbles: 7) }

  before do
    owner.reload
    member.reload
    post login_path, params: { user: { username: owner.username, password: "password123" } }
  end

  def post_completion(params)
    post "/chores/items/#{chore.id}/anonymous_completion",
      params:  params.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  context "with blank credit_user_id (anonymous branch)" do
    it "creates an anonymous, payout-skipped completion under the recorder" do
      expect { post_completion(credit_user_id: "") }
        .to change(ChoreCompletion, :count).by(1)
      expect(response).to have_http_status(:created)
      c = ChoreCompletion.last
      expect(c.anonymous).to be true
      expect(c.payout_skipped).to be true
      expect(c.paid_pebbles).to eq(0)
      expect(c.user_id).to eq(owner.id)
      body = JSON.parse(response.body)
      expect(body["anonymous"]).to be true
      expect(body["credited_to"]).to be_nil
    end
  end

  context "with credit_user_id of a household member" do
    it "runs ChoreCompleter under the credited user and pays them" do
      expect { post_completion(credit_user_id: member.id) }
        .to change(ChoreCompletion, :count).by(1)
      expect(response).to have_http_status(:created)
      c = ChoreCompletion.last
      expect(c.user_id).to eq(member.id)
      expect(c.anonymous).to be false
      expect(c.payout_skipped).to be false
      expect(c.paid_pebbles).to eq(7)
      body = JSON.parse(response.body)
      expect(body["credited_to"]).to eq({ "id" => member.id, "username" => member.username })
    end

    it "fires the Jil chore_completion trigger for the credited user" do
      # Ensure the chore exists before we start spying (its own
      # after_create_commit fires Jil.trigger and would otherwise pollute).
      chore
      allow(::Jil).to receive(:trigger)
      post_completion(credit_user_id: member.id)
      expect(::Jil).to have_received(:trigger).with(
        satisfy { |u| u.id == member.id },
        :chore_completion,
        satisfy { |payload| payload.is_a?(ChoreCompletion) && payload.execution_attrs[:action] == :completed },
      ).at_least(:once)
    end

    it "advances the credited user's streak, not the recorder's" do
      post_completion(credit_user_id: member.id)
      expect(ChoreStreak.find_by(user_id: member.id, chore_id: chore.id)&.current_streak).to eq(1)
      expect(ChoreStreak.find_by(user_id: owner.id, chore_id: chore.id)).to be_nil
    end
  end

  context "with credit_user_id outside the household" do
    it "silently falls back to anonymous rather than crediting the outsider" do
      expect { post_completion(credit_user_id: outsider.id) }
        .to change(ChoreCompletion, :count).by(1)
      c = ChoreCompletion.last
      expect(c.anonymous).to be true
      expect(c.user_id).to eq(owner.id)
      expect(c.paid_pebbles).to eq(0)
    end
  end
end
