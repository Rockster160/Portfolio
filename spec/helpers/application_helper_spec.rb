require "rails_helper"

RSpec.describe ApplicationHelper do
  describe "#icon_ref_tag" do
    let(:tiny_png) {
      "data:image/png;base64," \
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
    }

    it "is nil for nothing, so the caller's own fallback takes over" do
      expect(helper.icon_ref_tag(nil)).to be_nil
      expect(helper.icon_ref_tag("   ")).to be_nil
    end

    it "wraps an emoji as a glyph" do
      expect(helper.icon_ref_tag("🏢")).to eq(%(<span class="icon-glyph">🏢</span>))
    end

    it "renders a Tabler class as an icon" do
      expect(helper.icon_ref_tag("ti-flame")).to include(%(class="ti ti-flame icon-ti"))
    end

    it "renders an image reference as an image" do
      expect(helper.icon_ref_tag(tiny_png)).to include(%(<img), tiny_png)
      expect(helper.icon_ref_tag("https://example.com/logo.png")).to include("https://example.com/logo.png")
    end

    it "passes inline SVG through" do
      expect(helper.icon_ref_tag(%(<svg viewBox="0 0 1 1"></svg>))).to include("<svg")
    end

    describe "a household upload" do
      let(:user) { create(:user) }
      let(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
      let(:icon) {
        HouseholdIcon.create!(
          chore_household: household, uploaded_by_user: user,
          name: "Acme", image_data: tiny_png
        )
      }

      it "resolves the reference to the upload's image" do
        expect(helper.icon_ref_tag("hicon:#{icon.id}")).to include(tiny_png)
      end

      # Somebody deleted it. Nil rather than a broken image, so a chore falls
      # back to its broom and an application to its initials.
      it "is nil for a reference pointing at nothing" do
        expect(helper.icon_ref_tag("hicon:#{icon.id + 999}")).to be_nil
      end
    end
  end
end
