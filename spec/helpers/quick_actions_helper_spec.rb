require "rails_helper"

RSpec.describe QuickActionsHelper, type: :helper do
  describe "#mrkdwn with [hicon <name>]" do
    let(:user)      { create(:user) }
    let(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
    let(:tiny_png_url) {
      "data:image/png;base64," \
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
    }

    before do
      user.update!(chore_household: household)
      HouseholdIcon.create!(
        chore_household:  household,
        uploaded_by_user: user,
        name:             "Whisper",
        image_data:       tiny_png_url,
      )
      allow(helper).to receive(:current_user).and_return(user)
    end

    it "resolves to an <img> with the icon's data URL" do
      out = helper.mrkdwn("[hicon Whisper]").to_s
      expect(out).to include("<img")
      expect(out).to include(tiny_png_url)
    end

    it "is case- and separator-insensitive" do
      out = helper.mrkdwn("[hicon whisper]").to_s
      expect(out).to include(tiny_png_url)
    end

    it "renders ❌ when the icon is not found" do
      out = helper.mrkdwn("[hicon nope]").to_s
      expect(out).to include("❌")
      expect(out).not_to include("<img")
    end
  end
end
