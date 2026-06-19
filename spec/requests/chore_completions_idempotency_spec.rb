require "rails_helper"

# Covers the queue-first idempotency guarantees on the chore completion
# endpoints. The client write-ahead queue can replay POST/DELETE if the
# original response never made it back (page suspended, network died,
# etc.) — the server must dedupe by client_mutation_id so a replay is a
# no-op rather than a double-completion or wrong-row-deleted.
RSpec.describe "ChoreCompletions idempotency", type: :request do
  let(:user) { create(:user) }
  let(:chore) { create(:chore, created_by_user: user, name: "Brush", reward_pebbles: 5) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  describe "POST create" do
    let(:mid) { SecureRandom.uuid }

    it "stores client_mutation_id and dedupes a replayed POST" do
      expect {
        post "/chores/items/#{chore.id}/completion",
          params:  { client_mutation_id: mid }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.to change(ChoreCompletion, :count).by(1)
      expect(response).to have_http_status(:created)
      first = JSON.parse(response.body)
      expect(first["paid"]).to eq(5)
      expect(ChoreCompletion.last.client_mutation_id).to eq(mid)

      # Replay — same body, same mutation_id. Server must return the
      # prior completion's payload without creating a second row or
      # double-paying.
      expect {
        post "/chores/items/#{chore.id}/completion",
          params:  { client_mutation_id: mid }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.not_to change(ChoreCompletion, :count)
      expect(response).to have_http_status(:ok)
      replay = JSON.parse(response.body)
      expect(replay["deduped"]).to be true
      expect(replay["paid"]).to eq(5)
    end

    it "still works without a client_mutation_id (legacy/direct call)" do
      expect {
        post "/chores/items/#{chore.id}/completion",
          params:  {}.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.to change(ChoreCompletion, :count).by(1)
      expect(response).to have_http_status(:created)
      expect(ChoreCompletion.last.client_mutation_id).to be_nil
    end
  end

  describe "DELETE destroy_last_today" do
    let(:mid) { SecureRandom.uuid }

    it "deletes the targeted completion when target_client_mutation_id is given" do
      post "/chores/items/#{chore.id}/completion",
        params:  { client_mutation_id: mid }.to_json,
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      expect(ChoreCompletion.count).to eq(1)

      expect {
        delete "/chores/items/#{chore.id}/completion",
          params:  { target_client_mutation_id: mid }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.to change(ChoreCompletion, :count).by(-1)
      expect(response).to have_http_status(:ok)
    end

    it "returns deduped=true (200, no error) when the target is already gone" do
      # Simulates a queued DELETE that already flushed once successfully
      # but the response was lost; queue retries. Server must NOT 404 and
      # must NOT delete some other completion as collateral.
      expect {
        delete "/chores/items/#{chore.id}/completion",
          params:  { target_client_mutation_id: SecureRandom.uuid }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.not_to change(ChoreCompletion, :count)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["deduped"]).to be true
    end

    it "does NOT delete a sibling completion when targeted id is gone" do
      # A queued undo for id X1 replays after the user has done a fresh
      # complete X2. The replay must target X1 (gone) and leave X2 alone.
      sibling = create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)

      expect {
        delete "/chores/items/#{chore.id}/completion",
          params:  { target_client_mutation_id: SecureRandom.uuid }.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.not_to change(ChoreCompletion, :count)
      expect(ChoreCompletion.exists?(sibling.id)).to be true
    end

    it "falls back to most-recent-today when no target is given" do
      create(:chore_completion, chore: chore, user: user, paid_pebbles: 5)
      expect {
        delete "/chores/items/#{chore.id}/completion",
          params:  {}.to_json,
          headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
      }.to change(ChoreCompletion, :count).by(-1)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "unique index" do
    it "rejects two completions with the same client_mutation_id for the same user" do
      mid = SecureRandom.uuid
      create(:chore_completion, chore: chore, user: user, client_mutation_id: mid)
      expect {
        create(:chore_completion, chore: chore, user: user, client_mutation_id: mid)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows multiple completions with NULL client_mutation_id" do
      expect {
        create(:chore_completion, chore: chore, user: user, client_mutation_id: nil)
        create(:chore_completion, chore: chore, user: user, client_mutation_id: nil)
      }.not_to raise_error
    end
  end
end
