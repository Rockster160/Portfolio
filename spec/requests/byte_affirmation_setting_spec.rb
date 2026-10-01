require "rails_helper"

# Rocco, 2026-10-01: "Affirmation should just be a Quick Action that can be
# removed if the user so chooses."
#
# Everything else in that list is either a row with its own options or one of
# their own saved routines, which they can delete. Affirmation was neither: a
# hard-coded button, and the only one that cannot BE a routine - a routine runs
# deterministically with no model call (Buddy::Routines.run!) and an
# affirmation is a model turn by definition. So it is a preference, and turning
# it off is what deleting a routine would be for one of these.
RSpec.describe "Byte affirmation setting", type: :request do
  let(:user) { User.me }

  # The session cookie belongs to the host it was issued on, so anything
  # reading the page has to switch hosts BEFORE signing in.
  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  describe User do
    # Absent means on, which is what it was for everybody before the switch
    # existed - nobody is deciding about this by being asked.
    it "is on for somebody who has never touched it" do
      user.update!(byte_prefs: {})

      expect(user.byte_affirmation?).to be(true)
    end

    it "round-trips off and back on" do
      user.byte_affirmation = false
      user.save!
      expect(user.reload.byte_affirmation?).to be(false)

      user.byte_affirmation = true
      user.save!
      expect(user.reload.byte_affirmation?).to be(true)
    end

    # The row is what the setting is about, so nothing else in byte_prefs can
    # be disturbed by it.
    it "leaves the rest of the preferences alone" do
      user.update!(byte_prefs: { "font_scale" => 130 })
      user.byte_affirmation = false
      user.save!

      expect(user.reload.byte_font_scale).to eq(130)
    end
  end

  describe "the endpoint" do
    it "stores off and says so" do
      post byte_affirmation_action_path, params: { on: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["on"]).to be(false)
      expect(user.reload.byte_affirmation?).to be(false)
    end

    # The toggle paints from what comes back rather than from what was tapped,
    # so the answer has to be the stored value and not the request.
    it "stores on and says so" do
      user.byte_affirmation = false
      user.save!

      post byte_affirmation_action_path, params: { on: true }, as: :json

      expect(response.parsed_body["on"]).to be(true)
      expect(user.reload.byte_affirmation?).to be(true)
    end
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
