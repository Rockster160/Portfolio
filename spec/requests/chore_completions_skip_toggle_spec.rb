require "rails_helper"

# History-modal payout toggle: a manager can flip a completion between
# paid and skipped. `skipped_reason` is owned by the server (never sent
# by the form) and a skipped completion always pays 0, since the balance
# is a plain SUM(paid_pebbles).
RSpec.describe "ChoreCompletions payout_skipped toggle", type: :request do
  let(:owner) { create(:user) }
  let(:household) { create(:chore_household, owner_user: owner) }
  let(:chore) { create(:chore, created_by_user: owner, chore_household: household, reward_pebbles: 7) }
  let(:actor) { owner }

  before do
    actor.reload
    post login_path, params: { user: { username: actor.username, password: "password123" } }
  end

  def patch_completion(completion, attrs)
    patch "/chores/completions/#{completion.id}",
      params:  { chore_completion: attrs }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  def build_completion(**attrs)
    create(:chore_completion, { chore: chore, user: owner }.merge(attrs))
  end

  it "restores the payout on a skipped completion and clears the reason" do
    completion = build_completion(
      payout_skipped: true,
      skipped_reason: "Cooldown — resets at end of day",
      paid_pebbles:   0,
      base_pebbles:   7,
    )

    patch_completion(completion, payout_skipped: false, paid_pebbles: 7)

    expect(response).to have_http_status(:ok)
    completion.reload
    expect(completion.payout_skipped).to be false
    expect(completion.skipped_reason).to be_nil
    expect(completion.paid_pebbles).to eq(7)
  end

  it "skips a paid completion, zeroes the payout and stamps the reason" do
    completion = build_completion(payout_skipped: false, paid_pebbles: 7, base_pebbles: 7)

    patch_completion(completion, payout_skipped: true, paid_pebbles: 7)

    expect(response).to have_http_status(:ok)
    completion.reload
    expect(completion.payout_skipped).to be true
    expect(completion.paid_pebbles).to eq(0)
    expect(completion.skipped_reason).to eq("Skipped by hand")
  end

  it "leaves an existing reason alone when the flag does not move" do
    completion = build_completion(
      payout_skipped: true,
      skipped_reason: "Marked done by someone outside the household",
      paid_pebbles:   0,
    )

    patch_completion(completion, payout_skipped: true, note: "audited")

    expect(response).to have_http_status(:ok)
    completion.reload
    expect(completion.skipped_reason).to eq("Marked done by someone outside the household")
    expect(completion.note).to eq("audited")
  end

  it "rebuilds the streak when the flag flips" do
    completion = build_completion(payout_skipped: true, paid_pebbles: 0)
    expect(ChoreStreak).to receive(:rebuild_for!).with(owner, chore)

    patch_completion(completion, payout_skipped: false, paid_pebbles: 7)

    expect(response).to have_http_status(:ok)
  end

  context "when the actor is a plain household member" do
    let(:member) { create(:user) }
    let(:actor) { member }
    let!(:membership) {
      create(:chore_household_membership, chore_household: household, user: member, role: :member)
    }

    it "refuses the edit — members can't rewrite history" do
      completion = create(:chore_completion, chore: chore, user: member, payout_skipped: true, paid_pebbles: 0)

      patch_completion(completion, payout_skipped: false, paid_pebbles: 7)

      expect(response).to have_http_status(:forbidden)
      expect(completion.reload.payout_skipped).to be true
    end
  end
end
