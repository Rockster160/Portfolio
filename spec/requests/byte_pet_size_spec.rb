require "rails_helper"

# The pet carries a stated size and the hero band follows it, so the size is a
# per-person preference set from a stepper.
RSpec.describe "Byte pet size", type: :request do
  let(:user) { User.me }

  # The session cookie belongs to the host it was issued on, so anything
  # reading the page has to switch hosts BEFORE signing in.
  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  # Set from a stepper, with nowhere to put an error - so it is clamped
  # rather than rejected, the same as the text size.
  it "defaults, round-trips and clamps the size without touching other preferences", :aggregate_failures do
    user.update!(byte_prefs: { "font_scale" => 130 })
    expect(user.byte_pet_scale).to eq(100)

    user.update!(byte_pet_scale: 140)
    expect(user.reload.byte_pet_scale).to eq(140)
    expect(user.byte_font_scale).to eq(130)

    user.update!(byte_pet_scale: 5_000)
    expect(user.reload.byte_pet_scale).to eq(User::PET_SCALE_RANGE.max)

    user.update!(byte_pet_scale: 1)
    expect(user.reload.byte_pet_scale).to eq(User::PET_SCALE_RANGE.min)
  end

  it "stores a size from the endpoint and answers with the clamped value it stored", :aggregate_failures do
    post byte_pet_scale_path, params: { scale: 80 }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["scale"]).to eq(80)
    expect(user.reload.byte_pet_scale).to eq(80)

    post byte_pet_scale_path, params: { scale: 9_000 }, as: :json

    expect(response.parsed_body["scale"]).to eq(User::PET_SCALE_RANGE.max)
  end

  # Rendered inline so the first paint is already the right size.
  it "carries the size on the page as a custom property before any JS runs" do
    user.update!(byte_pet_scale: 70)
    host! "byte.example.com"
    sign_in

    get "/"

    expect(response.body).to include("--byte-pet-scale: 0.7")
    expect(response.body).to include('data-pet-scale="70"')
  end
end
