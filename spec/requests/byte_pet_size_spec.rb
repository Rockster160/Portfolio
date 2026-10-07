require "rails_helper"

# Rocco, 7 Oct 2026: "can we have the hero section grow with the Buddy itself?
# Right now it seems like the section grows and shrinks with the page and then
# occasionally hits break points which resize the Buddy. There is a LOT of
# empty space here [...] And/or a way to set a custom size for Buddy could be
# cool in the settings."
#
# Both halves are the same fact: the band was reserved in vh and the pet was
# capped in px, so the empty space between them was whatever the window said.
# The pet carries a stated size now and the band follows it - which makes the
# size worth offering, because shrinking the pet is how you get more thread.
RSpec.describe "Byte pet size", type: :request do
  let(:user) { User.me }

  # The session cookie belongs to the host it was issued on, so anything
  # reading the page has to switch hosts BEFORE signing in.
  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  describe User do
    it "is the design size for somebody who has never touched it" do
      user.update!(byte_prefs: {})

      expect(user.byte_pet_scale).to eq(100)
    end

    it "round-trips a chosen size" do
      user.update!(byte_pet_scale: 140)

      expect(user.reload.byte_pet_scale).to eq(140)
    end

    # Set from a stepper, with nowhere to put an error - so it is clamped
    # rather than rejected, the same as the text size.
    it "clamps rather than refusing" do
      user.update!(byte_pet_scale: 5_000)
      expect(user.reload.byte_pet_scale).to eq(User::PET_SCALE_RANGE.max)

      user.update!(byte_pet_scale: 1)
      expect(user.reload.byte_pet_scale).to eq(User::PET_SCALE_RANGE.min)
    end

    it "leaves the rest of the preferences alone" do
      user.update!(byte_prefs: { "font_scale" => 130 })
      user.update!(byte_pet_scale: 80)

      expect(user.reload.byte_font_scale).to eq(130)
    end
  end

  describe "the endpoint" do
    it "stores a size and says what it stored" do
      post byte_pet_scale_path, params: { scale: 80 }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["scale"]).to eq(80)
      expect(user.reload.byte_pet_scale).to eq(80)
    end

    it "answers with the clamped value rather than the one it was sent" do
      post byte_pet_scale_path, params: { scale: 9_000 }, as: :json

      expect(response.parsed_body["scale"]).to eq(User::PET_SCALE_RANGE.max)
    end
  end

  # Rendered inline so the first paint is already the right size - a pet that
  # arrives at the design size and then jumps is the thing the stated height
  # was supposed to stop.
  #
  # The page lives on its own subdomain (`/byte` is a redirect to it), and the
  # session cookie belongs to the host it was issued on - so the host switch
  # comes before the sign-in, not after.
  describe "the page" do
    it "carries the size as a custom property before any JS runs" do
      user.update!(byte_pet_scale: 70)
      host! "byte.example.com"
      sign_in

      get "/"

      expect(response.body).to include("--byte-pet-scale: 0.7")
      expect(response.body).to include('data-pet-scale="70"')
    end
  end
end
