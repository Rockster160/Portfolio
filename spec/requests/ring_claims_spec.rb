require "rails_helper"

RSpec.describe "Ring claims", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }
  let(:sounding) { { owner_id: user.id, key: "wake", at: 1_800_000_000, slot: 0 } }

  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  def sign_in
    user.update!(password: password, password_confirmation: password)
    post "/login", params: { user: { username: user.username, password: password } }
  end

  it "gives a sounding to the first screen that claims it and no other" do
    sign_in

    post "/ring_claims", params: sounding, as: :json
    expect(response.parsed_body).to eq("play" => true)

    post "/ring_claims", params: sounding, as: :json
    expect(response.parsed_body).to eq("play" => false)

    post "/ring_claims", params: sounding.merge(slot: 1), as: :json
    expect(response.parsed_body).to eq("play" => true)
  end

  it "refuses a claim with nothing to identify it" do
    sign_in

    post "/ring_claims", params: { key: "", at: 0 }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "is for signed-in screens only" do
    post "/ring_claims", params: sounding, as: :json
    expect(response).not_to have_http_status(:ok)
  end
end
