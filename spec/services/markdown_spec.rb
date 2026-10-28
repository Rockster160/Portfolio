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

  describe "[hicon:ID]" do
    let(:user)          { create(:user) }
    let(:household)     { ChoreHousehold.create!(name: "Home", owner_user: user) }
    let(:other_user)    { create(:user) }
    let(:other_house)   { ChoreHousehold.create!(name: "Away", owner_user: other_user) }
    let(:tiny_png_url) {
      "data:image/png;base64," \
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
    }
    let!(:icon) {
      user.update!(chore_household: household)
      HouseholdIcon.create!(
        chore_household:  household,
        uploaded_by_user: user,
        name:             "Whisper",
        image_data:       tiny_png_url,
      )
    }

    it "resolves the id to the household icon's <img>" do
      out = described_class.new("[hicon:#{icon.id}]", user: user).to_html.to_s
      expect(out).to include("<img")
      expect(out).to include(tiny_png_url)
      expect(out).to include('alt="Whisper"')
    end

    it "renders ❌ for an id that doesn't exist" do
      out = described_class.new("[hicon:999999]", user: user).to_html.to_s
      expect(out).to include("❌")
      expect(out).not_to include("<img")
    end

    it "renders ❌ for an id from a different household" do
      other_user.update!(chore_household: other_house)
      out = described_class.new("[hicon:#{icon.id}]", user: other_user).to_html.to_s
      expect(out).to include("❌")
      expect(out).not_to include(tiny_png_url)
    end

    it "renders ❌ when no user context is supplied" do
      out = described_class.new("[hicon:#{icon.id}]").to_html.to_s
      expect(out).to include("❌")
    end
  end

  describe "[ticon:ti-*]" do
    it "renders a Tabler icon <i> element" do
      out = described_class.new("[ticon:ti-broom]").to_html.to_s
      expect(out).to include('class="ti ti-broom"')
    end

    it "leaves non-ti classes untouched (regex whitelist)" do
      out = described_class.new("[ticon:evil-class]").to_html.to_s
      expect(out).to include("[ticon:evil-class]")
      expect(out).not_to include("class=\"ti")
    end

    it "leaves bare class references (no ti- prefix) untouched" do
      out = described_class.new("[ticon:broom]").to_html.to_s
      expect(out).to include("[ticon:broom]")
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
  describe "block quotes" do
    it "renders a run of quoted lines as one quote, with the soft wraps joined up" do
      out = html("> I built the backfill tooling\n> first. Backfilling tables with millions\n> of rows one script at a time is how you end up half-migrated.")
      expect(out.scan("<blockquote>").size).to eq(1)
      expect(out).to include("backfill tooling first. Backfilling tables with millions of rows")
    end

    it "keeps a blank quoted line as the break between two quoted paragraphs" do
      out = html("> One thing.\n>\n> Another thing.")
      expect(out.scan("<blockquote>").size).to eq(1)
      expect(out).to match(%r{One thing\.(<br\s*/?>){2}Another thing\.})
    end

    it "leaves two quotes with ordinary text between them as two quotes" do
      out = html("> First.\n\nSomething said.\n\n> Second.")
      expect(out.scan("<blockquote>").size).to eq(2)
    end
  end
end
