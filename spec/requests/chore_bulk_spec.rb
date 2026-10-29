require "rails_helper"

RSpec.describe "Chore bulk actions", type: :request do
  let(:user) { create(:user) }
  let!(:vacuum) { create(:chore, created_by_user: user, name: "Vacuum") }
  let!(:dishes) { create(:chore, created_by_user: user, name: "Dishes", tags: ["Kitchen"]) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def json = response.parsed_body

  def bulk(**body)
    post "/chores/bulk", params: body.to_json, headers: {
      "CONTENT_TYPE" => "application/json",
      "ACCEPT"       => "application/json",
    }
  end

  it "marks every picked chore due today" do
    bulk(op: :mark_due, ids: [vacuum.id, dishes.id])
    expect(response).to have_http_status(:ok)
    expect([vacuum.reload, dishes.reload].map(&:marked_due_at)).to all(be_present)
    expect(json["count"]).to eq(2)
    expect(json["chores"].pluck("id")).to include(vacuum.id, dishes.id)
  end

  it "makes every picked chore due on the day given" do
    day = ChoreDay.current(user) + 3
    bulk(op: :mark_due, ids: [vacuum.id, dishes.id], due_on: day.iso8601)
    expect([vacuum.reload, dishes.reload].map(&:marked_due_at)).to all(eq(ChoreDay.starts_at(day, user)))
  end

  it "completes them for somebody outside the household when nobody is named" do
    bulk(op: :complete, ids: [vacuum.id, dishes.id], credit_user_id: "")
    expect(response).to have_http_status(:ok)
    rows = ChoreCompletion.where(chore: [vacuum, dishes])
    expect(rows.map(&:anonymous)).to eq([true, true])
    expect(rows.map(&:payout_skipped)).to eq([true, true])
  end

  it "completes every picked chore for the member at the time given" do
    at = 2.days.ago.change(usec: 0)
    bulk(op: :complete, ids: [vacuum.id, dishes.id], credit_user_id: user.id, completed_at: at.iso8601)
    expect(response).to have_http_status(:ok)
    rows = ChoreCompletion.where(chore: [vacuum, dishes])
    expect(rows.map(&:user_id)).to eq([user.id, user.id])
    expect(rows.map(&:completed_at)).to all(eq(at))
  end

  it "refuses a completion credited to someone outside the household" do
    bulk(op: :complete, ids: [vacuum.id], credit_user_id: create(:user).id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(ChoreCompletion.where(chore: vacuum)).to be_empty
  end

  it "adds a group without doubling one a chore already has" do
    bulk(op: :tag, ids: [vacuum.id, dishes.id], tag: "kitchen")
    expect(vacuum.reload.tags).to eq(["kitchen"])
    expect(dishes.reload.tags).to eq(["Kitchen"])
  end

  it "takes a group off whatever its casing" do
    bulk(op: :untag, ids: [dishes.id], tag: "kitchen")
    expect(dishes.reload.tags).to eq([])
  end

  it "leaves chores the viewer cannot reach alone" do
    stranger = create(:chore, name: "Not yours")
    bulk(op: :mark_due, ids: [stranger.id])
    expect(response).to have_http_status(:unprocessable_entity)
    expect(stranger.reload.marked_due_at).to be_nil
  end
end
