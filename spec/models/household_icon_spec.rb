require "rails_helper"

RSpec.describe HouseholdIcon, type: :model do
  let(:user)      { create(:user) }
  let(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let(:tiny_png_url) {
    "data:image/png;base64," \
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=="
  }

  subject(:icon) {
    described_class.new(
      chore_household:  household,
      uploaded_by_user: user,
      name:             "Whisper",
      keywords:         "cat, kitty",
      image_data:       tiny_png_url,
    )
  }

  it "is valid with required fields" do
    expect(icon).to be_valid
  end

  it "requires a name" do
    icon.name = ""
    expect(icon).not_to be_valid
  end

  it "requires image_data to be a data:image/ URL" do
    icon.image_data = "https://example.com/cat.png"
    expect(icon).not_to be_valid
    expect(icon.errors[:image_data]).to include("must be a data:image/* URL")
  end

  it "rejects oversized image_data" do
    icon.image_data = "data:image/png;base64,#{'A' * described_class::MAX_IMAGE_BYTES}"
    expect(icon).not_to be_valid
  end

  it "enforces unique name within a household (case-insensitive)" do
    icon.save!
    dup = described_class.new(
      chore_household:  household,
      uploaded_by_user: user,
      name:             "whisper",
      image_data:       tiny_png_url,
    )
    expect(dup).not_to be_valid
  end

  describe "#as_pool_row" do
    it "returns the picker-pool envelope, merging name words into k" do
      icon.name = "Whisper Cat"
      row = icon.as_pool_row
      expect(row[:c]).to eq(tiny_png_url)
      expect(row[:n]).to eq("Whisper Cat")
      expect(row[:k]).to include("cat", "kitty", "whisper")
    end
  end

  describe "#keyword_list" do
    it "splits on commas and newlines, strips, drops empties" do
      icon.keywords = "cat, kitty,\n furry  "
      expect(icon.keyword_list).to eq(["cat", "kitty", "furry"])
    end
  end

  describe ".lookup" do
    before do
      user.update!(chore_household: household)
      icon.save!
    end

    it "finds by exact name" do
      expect(described_class.lookup(user, "Whisper")).to eq(icon)
    end

    it "is case-insensitive" do
      expect(described_class.lookup(user, "whisper")).to eq(icon)
      expect(described_class.lookup(user, "WHISPER")).to eq(icon)
    end

    it "collapses spaces, underscores, and dashes" do
      icon.update!(name: "Animal Crossing Leaf")
      expect(described_class.lookup(user, "animal-crossing-leaf")).to eq(icon)
      expect(described_class.lookup(user, "animal_crossing_leaf")).to eq(icon)
      expect(described_class.lookup(user, "animal   crossing   leaf")).to eq(icon)
    end

    it "returns nil when name doesn't match any icon" do
      expect(described_class.lookup(user, "nope")).to be_nil
    end

    it "returns nil for nil/blank user or name" do
      expect(described_class.lookup(nil, "Whisper")).to be_nil
      expect(described_class.lookup(user, nil)).to be_nil
      expect(described_class.lookup(user, "")).to be_nil
    end

    it "returns nil when the user has no household" do
      loner = create(:user)
      expect(described_class.lookup(loner, "Whisper")).to be_nil
    end
  end
end
