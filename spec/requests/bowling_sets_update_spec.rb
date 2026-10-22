require "rails_helper"

RSpec.describe "Bowling series update", type: :request do
  let(:user) { create(:user) }
  let(:league) { BowlingLeague.create!(user: user, name: "Tuesday") }
  let(:set) { BowlingSet.create!(league: league) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  it "saves a series that has no games yet" do
    patch bowling_set_path(set), params: { bowling_set: { league_id: league.id, lane_number: 7 } }, as: :json

    expect(response).to have_http_status(:created)
    expect(set.reload.lane_number).to eq(7)
  end
end
