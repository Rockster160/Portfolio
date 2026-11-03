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

    it "resolves a name case-insensitively, and renders ❌ for an unknown name or no user" do
      out = described_class.new("[hicon whisper]", user: user).to_html.to_s
      expect(out).to include("<img", tiny_png_url)

      missing = described_class.new("[hicon nope]", user: user).to_html.to_s
      expect(missing).to include("❌")
      expect(missing).not_to include("<img")

      expect(described_class.new("[hicon Whisper]").to_html.to_s).to include("❌")
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

    it "resolves an id within the viewer's household only" do
      out = described_class.new("[hicon:#{icon.id}]", user: user).to_html.to_s
      expect(out).to include("<img", tiny_png_url, 'alt="Whisper"')

      missing = described_class.new("[hicon:999999]", user: user).to_html.to_s
      expect(missing).to include("❌")
      expect(missing).not_to include("<img")

      other_user.update!(chore_household: other_house)
      foreign = described_class.new("[hicon:#{icon.id}]", user: other_user).to_html.to_s
      expect(foreign).to include("❌")
      expect(foreign).not_to include(tiny_png_url)

      expect(described_class.new("[hicon:#{icon.id}]").to_html.to_s).to include("❌")
    end
  end

  describe "[ticon:ti-*]" do
    it "renders a Tabler icon <i> element, and only for a ti- class" do
      expect(described_class.new("[ticon:ti-broom]").to_html.to_s).to include('class="ti ti-broom"')

      ["[ticon:evil-class]", "[ticon:broom]"].each { |text|
        out = described_class.new(text).to_html.to_s
        expect(out).to include(text)
        expect(out).not_to include("class=\"ti")
      }
    end
  end

  describe "ordered lists" do
    it "does not wrap a single numbered line or a leading number in <ol>" do
      ["1. milk", "2 eggs", "3) party hats"].each { |text| expect(html(text)).not_to include("<ol>"), text }
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
