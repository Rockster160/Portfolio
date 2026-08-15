require "rails_helper"

# Tapping a chore that's been split into per-person sub-chores.
#
# The container is the card people actually see: the Hot strip shows the
# PICK, and picks land on the parent (a `hot_eligibility: never` sub is
# rejected outright, an unscheduled container survives). Tapping it used to
# write a completion against the family, which credits neither half — the
# person's own card stayed unticked and the schedule under it never moved.
RSpec.describe "Tapping a per-person container chore", type: :request do
  let(:owner) { create(:user) }
  let(:household) { create(:chore_household, owner_user: owner) }
  let(:partner) { create(:user) }
  let!(:partner_membership) {
    create(:chore_household_membership, chore_household: household, user: partner, role: :member)
  }

  let!(:parent) {
    create(
      :chore,
      created_by_user: owner, chore_household: household, name: "Shower",
      show_on_today_view: :never, reward_pebbles: 4
    )
  }
  let!(:mine) {
    create(
      :chore,
      created_by_user: owner, chore_household: household, name: "Shower",
      parent_chore: parent, assigned_to_user: owner, reward_pebbles: 4
    )
  }
  let!(:theirs) {
    create(
      :chore,
      created_by_user: partner, chore_household: household, name: "Shower",
      parent_chore: parent, assigned_to_user: partner, reward_pebbles: 4
    )
  }

  before do
    owner.reload
    partner.reload
    post login_path, params: { user: { username: owner.username, password: "password123" } }
  end

  def tap_chore(chore, params={})
    post "/chores/items/#{chore.id}/completion",
      params:  params.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  def undo_chore(chore, params={})
    delete "/chores/items/#{chore.id}/completion",
      params:  params.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  it "records the tapper's own sub-chore, not the container" do
    expect { tap_chore(parent) }.to change(ChoreCompletion, :count).by(1)

    completion = ChoreCompletion.last
    expect(completion.chore_id).to eq(mine.id)
    expect(completion.parent_chore_id).to eq(parent.id)
    expect(completion.user_id).to eq(owner.id)
    expect(theirs.chore_completions).to be_empty
    # The response carries the sub-chore so the card that was unticked is
    # the one the client hears about.
    expect(response.parsed_body.dig("chore", "id")).to eq(mine.id)
  end

  it "pays the container's hot multiplier on the redirected tap" do
    create(:chore_hot_pick, chore: parent, multiplier: 2.0, day_key: ChoreDay.current(owner))
    tap_chore(parent)

    completion = ChoreCompletion.last
    expect(completion.hot_multiplier).to eq(2.0)
    expect(completion.paid_pebbles).to eq(8) # sub's 4 reward × the parent's pick
  end

  it "still advances the container's streak" do
    tap_chore(parent)

    expect(ChoreStreak.find_by(user_id: owner.id, chore_id: parent.id)&.current_streak).to eq(1)
    expect(ChoreStreak.find_by(user_id: owner.id, chore_id: mine.id)).to be_nil
  end

  it "undoes a container tap even without the mutation id to target" do
    tap_chore(parent)
    expect { undo_chore(parent) }.to change(ChoreCompletion, :count).by(-1)
    expect(response).to have_http_status(:ok)
    expect(mine.chore_completions).to be_empty
  end

  it "undoes a container tap by the mutation id the client kept" do
    tap_chore(parent, client_mutation_id: "abc-123")
    expect { undo_chore(parent, target_client_mutation_id: "abc-123") }
      .to change(ChoreCompletion, :count).by(-1)
    expect(response.parsed_body.dig("chore", "id")).to eq(mine.id)
  end

  it "credits the named member's own sub-chore when completing on their behalf" do
    post "/chores/items/#{parent.id}/anonymous_completion",
      params:  { credit_user_id: partner.id }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    completion = ChoreCompletion.last
    expect(completion.chore_id).to eq(theirs.id)
    expect(completion.user_id).to eq(partner.id)
  end

  # Nobody is named on an anonymous completion, so there's no whose-sub to
  # answer. It stays on the container, where it still counts for the
  # family's cooldown and carryover.
  it "leaves a truly anonymous completion on the container" do
    post "/chores/items/#{parent.id}/anonymous_completion",
      params:  { credit_user_id: "" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }

    expect(ChoreCompletion.last.chore_id).to eq(parent.id)
  end

  # The narrow half of the rule: a parent whose children are per-item
  # rather than per-person is a thing people tap on purpose.
  context "when the children are per item rather than per person" do
    let!(:supplements) {
      create(:chore, created_by_user: owner, chore_household: household, name: "Supplements", reward_pebbles: 2)
    }
    let!(:focus_med) {
      create(
        :chore, created_by_user: owner, chore_household: household, name: "Focus",
        parent_chore: supplements, assigned_to_user: owner, reward_pebbles: 2
      )
    }
    let!(:cymbalta) {
      create(
        :chore, created_by_user: owner, chore_household: household, name: "Cymbalta",
        parent_chore: supplements, assigned_to_user: owner, reward_pebbles: 2
      )
    }

    it "honors the tap exactly and never guesses which child was meant" do
      tap_chore(supplements)

      expect(ChoreCompletion.last.chore_id).to eq(supplements.id)
      expect(focus_med.chore_completions).to be_empty
      expect(cymbalta.chore_completions).to be_empty
    end

    it "still records the leaf when the leaf itself is tapped" do
      tap_chore(cymbalta)

      expect(ChoreCompletion.last.chore_id).to eq(cymbalta.id)
    end
  end
end
