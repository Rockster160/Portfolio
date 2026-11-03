require "rails_helper"

# Affirmation is a model turn, so it can't be a routine; turning it off is a
# preference stored in byte_prefs.
RSpec.describe "Byte affirmation setting", type: :request do
  let(:user) { User.me }

  # The session cookie belongs to the host it was issued on, so anything
  # reading the page has to switch hosts BEFORE signing in.
  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  # Absent means on, which is what it was for everybody before the switch existed.
  it "is on by default and round-trips without touching other preferences", :aggregate_failures do
    user.update!(byte_prefs: { "font_scale" => 130 })
    expect(user.byte_affirmation?).to be(true)

    user.byte_affirmation = false
    user.save!
    expect(user.reload.byte_affirmation?).to be(false)
    expect(user.byte_font_scale).to eq(130)

    user.byte_affirmation = true
    user.save!
    expect(user.reload.byte_affirmation?).to be(true)
  end

  # The toggle paints from what comes back rather than from what was tapped,
  # so the answer has to be the stored value and not the request.
  it "stores off and on from the endpoint and answers with the stored value", :aggregate_failures do
    post byte_affirmation_action_path, params: { on: false }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["on"]).to be(false)
    expect(user.reload.byte_affirmation?).to be(false)

    post byte_affirmation_action_path, params: { on: true }, as: :json

    expect(response.parsed_body["on"]).to be(true)
    expect(user.reload.byte_affirmation?).to be(true)
  end

  # The page itself lives on the byte subdomain, and the constraint only reads
  # one off a host with a real TLD - "byte.localhost" renders the home page.
  describe "the actions list" do
    before {
      host! "byte.example.com"
      sign_in
    }

    it "draws the row when it is on" do
      get byte_root_path

      expect(response.body).to include('data-buddy-action="affirmation"')
      expect(response.body).not_to match(/data-byte-affirmation-row\s*\n?\s*hidden/)
    end

    it "hides the row when it is off" do
      user.byte_affirmation = false
      user.save!

      get byte_root_path

      expect(response.body).to match(/data-byte-affirmation-row\s*\n?\s*hidden/)
    end
  end
end
