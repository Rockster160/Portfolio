require "rails_helper"

RSpec.describe PromptSearch do
  let(:user) { create(:user) }
  let(:other) { create(:user) }
  let(:option) { { query: "action_events:print" } }
  let(:finder) { described_class.new(user, option) }

  let!(:dragon) {
    user.action_events.create!(
      name: "Print", notes: "Dragon v2", timestamp: 2.days.ago, data: { color: "#ff8800", icon: "🐉" },
    )
  }
  let!(:benchy) { user.action_events.create!(name: "Print", notes: "Benchy", timestamp: 1.day.ago) }
  let!(:dragon_meal) { user.action_events.create!(name: "Food", notes: "Dragon fruit", timestamp: 1.hour.ago) }
  let!(:theirs) { other.action_events.create!(name: "Print", notes: "Dragon", timestamp: 1.hour.ago) }

  describe "#results" do
    it "adds what was typed to the question's own search" do
      expect(finder.results("dragon").pluck(:id)).to eq([dragon.id])
    end

    it "shows the newest the base search finds before anything is typed" do
      expect(finder.results("").pluck(:id)).to eq([benchy.id, dragon.id])
    end

    it "never reaches another person's records" do
      expect(finder.results("dragon").pluck(:id)).not_to include(theirs.id)
    end

    it "takes the search syntax in the question" do
      finder = described_class.new(user, query: "action_events:name::food")
      expect(finder.results("").pluck(:id)).to eq([dragon_meal.id])
    end

    it "finds nothing for a source it doesn't know" do
      expect(described_class.new(user, query: "users:admin").results("x")).to eq([])
    end

    it "draws each result from the source's own layout" do
      hit = finder.results("dragon").first
      expect(hit[:title]).to eq("Print")
      expect(hit[:detail_html]).to include("Dragon v2")
    end

    it "fills a template from columns and jsonb paths, shaped by filters" do
      option.merge!(title: "{data.color|swatch} {notes}", detail: "**{data.icon}**\n{timestamp|date}")
      hit = finder.results("dragon").first

      expect(hit[:title]).to eq("Dragon v2")
      expect(hit[:title_html]).to include("md-swatch", "background-color: #ff8800", "Dragon v2")
      expect(hit[:detail_html]).to include("<strong>🐉</strong>")
      expect(hit[:detail_html]).to include(dragon.timestamp.in_time_zone(user.timezone).strftime("%b %-d, %Y"))
    end

    it "keeps the title to one line" do
      option.merge!(title: "{name}\n{notes}")
      expect(finder.results("dragon").first[:title_html]).not_to include("<br")
    end

    it "escapes what a record holds rather than drawing it" do
      user.action_events.create!(name: "Print", notes: "<script>x</script> dragon")
      option.merge!(title: "{notes}")
      expect(finder.results("script").first[:title_html]).not_to include("<script>")
    end

    it "matches every word against a list item or its list" do
      list = create(:list, name: "Filament", user: user)
      red = create(:list_item, list: list, name: "PLA Red")
      create(:list_item, list: create(:list, name: "Groceries", user: user), name: "Red apples")

      finder = described_class.new(user, query: "list_items:filament")
      expect(finder.results("red").pluck(:id)).to eq([red.id])
    end

    it "turns a stored icon into something markdown draws" do
      household = ChoreHousehold.create!(name: "Mine", owner_user: user)
      user.update!(chore_household_id: household.id)
      create(:chore, created_by_user: user, chore_household: household, name: "Litter", icon: "ti-cat")

      hit = described_class.new(user, query: "chores:").results("litter").first
      expect(hit[:title]).to eq("Litter")
      expect(hit[:title_html]).to include("ti ti-cat")
    end
  end

  describe "#answer" do
    it "keeps a pick the search still finds, with the record's own title" do
      expect(finder.answer({ "id" => dragon.id.to_s, "title" => "anything" })).to eq(
        "id" => dragon.id, "title" => "Print",
      )
    end

    it "refuses an id the question would never have offered" do
      expect { finder.answer({ "id" => dragon_meal.id, "title" => "Food" }) }.to raise_error(described_class::Invalid)
      expect { finder.answer({ "id" => theirs.id, "title" => "Print" }) }.to raise_error(described_class::Invalid)
    end

    it "searches for words and takes the best match" do
      expect(finder.answer("benchy")).to eq("id" => benchy.id, "title" => "Print")
    end

    it "refuses words that find nothing" do
      expect { finder.answer("unicorn") }.to raise_error(described_class::Invalid, /nothing found/)
    end

    it "keeps typed text when free text is allowed" do
      option[:free_text] = true
      expect(finder.answer({ "id" => "", "title" => "Unicorn" })).to eq("id" => nil, "title" => "Unicorn")
    end

    it "answers with a list when several are allowed" do
      option[:multiple] = true
      picks = { "0" => { "id" => dragon.id }, "1" => { "id" => benchy.id }, "2" => { "id" => dragon.id } }
      expect(finder.answer(picks).pluck("id")).to eq([dragon.id, benchy.id])
    end

    it "answers nothing for nothing" do
      expect(finder.answer("")).to be_nil
    end
  end

  describe "#present" do
    it "draws a saved pick the way the dropdown drew it" do
      option[:title] = "{data.color|swatch} {notes}"
      shown = finder.present({ "id" => dragon.id, "title" => "Dragon v2" })
      expect(shown).to include("id" => dragon.id, "title" => "Dragon v2")
      expect(shown["html"]).to include("md-swatch")
    end

    it "keeps the saved words for a record that is gone" do
      expect(finder.present({ "id" => 0, "title" => "<b>Old</b>" })).to eq(
        "id" => 0, "title" => "<b>Old</b>", "html" => "&lt;b&gt;Old&lt;/b&gt;",
      )
    end
  end
end
