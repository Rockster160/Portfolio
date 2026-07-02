require "rails_helper"

RSpec.describe Markdown do
  def html(text) = described_class.new(text).to_html.to_s

  describe "[hicon <name>]" do
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
    end

    it "resolves to an <img> with the icon's data URL" do
      out = described_class.new("[hicon Whisper]", user: user).to_html.to_s
      expect(out).to include("<img")
      expect(out).to include(tiny_png_url)
      expect(out).to include('alt="Whisper"')
    end

    it "is case- and separator-insensitive" do
      out = described_class.new("[hicon whisper]", user: user).to_html.to_s
      expect(out).to include(tiny_png_url)
    end

    it "renders ❌ when the icon is not found" do
      out = described_class.new("[hicon nope]", user: user).to_html.to_s
      expect(out).to include("❌")
      expect(out).not_to include("<img")
    end

    it "renders ❌ when no user context is supplied" do
      out = described_class.new("[hicon Whisper]").to_html.to_s
      expect(out).to include("❌")
    end
  end

  describe "ordered lists" do
    it "does not wrap a single numbered line in <ol>" do
      expect(html("1. milk")).not_to include("<ol>")
    end

    it "does not wrap a leading number in <ol> for typical list-item text" do
      expect(html("2 eggs")).not_to include("<ol>")
      expect(html("3) party hats")).not_to include("<ol>")
    end

    it "wraps two or more consecutive numbered lines in <ol>" do
      out = html("1. milk\n2. eggs")
      expect(out).to include("<ol>")
      expect(out).to include("<li>milk</li>")
      expect(out).to include("<li>eggs</li>")
    end
  end
end
