require "rails_helper"

# The one chore search every picker uses: the Chores page's box, and a board's
# pin and credit-button pickers.
RSpec.describe "Chore search" do
  let(:chores) {
    [
      { id: 1, name: "Feed Spiders", short_name: "Spiders", aliases: ["tarantulas"] },
      { id: 2, name: "Spray spiders", short_name: "Spray", aliases: [] },
      { id: 3, name: "Litter box", short_name: "Litter", aliases: ["cat poop"] },
    ]
  }

  let(:found) {
    JsRunner.eval_module(<<~JS)
      const { searchChores } = await import(#{Rails.root.join("app/javascript/src/chore_search.js").to_s.to_json});
      const chores = #{chores.to_json};
      const ids = (q) => searchChores(chores, q).map((c) => c.id);
      process.stdout.write(JSON.stringify({ tarantula: ids("tarantula"), poop: ids("poop"), spi: ids("spi"), all: ids("") }));
    JS
  }

  it "finds a chore by an alias as well as its name" do
    expect(found["tarantula"]).to eq([1])
    expect(found["poop"]).to eq([3])
  end

  # The short name is what a chore is called on every surface, so it's what
  # the search reads, with the aliases.
  it "searches the short name, not the full one" do
    expect(found["spi"]).to eq([1])
  end

  it "offers everything for an empty search" do
    expect(found["all"]).to contain_exactly(1, 2, 3)
  end
end
