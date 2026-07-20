require "rails_helper"

RSpec.describe ActionEventsController, type: :controller do
  let(:user) { create(:user) }
  let(:other) { create(:user) }

  before { sign_in user }

  describe "GET #latest" do
    it "returns the most-recent timestamp per query, scoped to current user" do
      old = ActionEvent.create!(user: user, name: "P", timestamp: 10.days.ago)
      newest = ActionEvent.create!(user: user, name: "P", timestamp: 1.day.ago)
      ActionEvent.create!(user: other, name: "P", timestamp: 1.hour.ago) # must not leak
      ActionEvent.create!(user: user, name: "Haircut", timestamp: 3.days.ago)

      get :latest, params: { queries: ["name::P", "name::Haircut", "name::Nope"] }, format: :json

      body = JSON.parse(response.body)
      expect(Time.parse(body["name::P"])).to be_within(1.second).of(newest.timestamp)
      expect(body["name::Haircut"]).to be_present
      expect(body["name::Nope"]).to be_nil
      expect(Time.parse(body["name::P"])).not_to be_within(1.second).of(old.timestamp)
    end

    it "returns empty hash when no queries provided" do
      get :latest, format: :json
      expect(JSON.parse(response.body)).to eq({})
    end
  end
end
