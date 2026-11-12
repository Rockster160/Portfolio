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

  it "puts an emoji ahead of a character who shares its name" do
    expect(cases[:cookie_first]).to eq("emoji")
  end
end
