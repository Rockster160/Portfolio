require "rails_helper"

# Animal Crossing faces are in the icon pool for a person picking by hand, and
# found by name or by what the character is. Nothing that guesses an icon from
# a name ever lands on one.
RSpec.describe "character faces in the icon pool (JS-side)" do
  let(:cases) { JsRunner.output("spec/javascript/icon_pool_characters_runner.js", symbolize: true)[:cases] }

  it "leaves faces out of a search that didn't ask for them, without fetching them" do
    expect(cases[:guess_only]).to eq(faces: [], fetched_index: false)
    expect(cases[:best_match]).not_to eq("character")
  end

  it "finds a character by name, stored as their face, with their attributes" do
    expect(cases[:by_name]).to eq(
      name:        "Raymond",
      value:       "/acnh/faces/cat23.png",
      personality: "Smug",
      species:     "Cat",
    )
  end

  it "ranks the character matching both attributes ahead of those matching one" do
    expect(cases[:smug_cats].first).to eq("Raymond")
  end

  it "puts the one named first, even among words that don't describe it" do
    expect(cases[:named_among_descriptions]).to eq("Doc")
  end

  it "finds villagers added in later game versions, by their face" do
    expect(cases[:cece]).to eq(n: "Cece", c: "/acnh/faces/squ19.png")
  end

  it "finds a name with an accent whether or not the search types it" do
    expect(cases[:viche_unaccented]).to eq("Viché")
    expect(cases[:pave_accented]).to eq("Pavé")
  end

  it "has an image on disk for every face in the index" do
    index = JSON.parse(Rails.public_path.join("acnh_index.json").read)
    missing = index.reject { |row| Rails.public_path.join(row["c"].delete_prefix("/")).exist? }

    expect(missing.pluck("n")).to eq([])
  end

  it "finds a name with punctuation whether or not the search types it" do
    expect(cases[:kk_punctuation]).to eq(["K.K.", "K.K.", "K.K."])
  end

  it "puts an emoji ahead of a character who shares its name" do
    expect(cases[:cookie_first]).to eq("emoji")
  end
end
