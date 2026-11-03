require "rails_helper"

# The keyboard half of the search-everything box: which hit up/down lands on,
# what Enter opens, and which keys open the overlay.
RSpec.describe "Global search keyboard navigation" do # rubocop:disable RSpec/DescribeClass
  let(:result) {
    JsRunner.eval_module(
      <<~JS,
        const nav = await import(#{Rails.root.join("app/javascript/src/global_search/nav.js").to_s.to_json});
        const groups = [
          { group: "lists", results: [{ url: "/a" }, { url: "/b" }] },
          { group: "chores", results: [{ url: "/c" }] },
        ];
        const hits = nav.flatten(groups);
        process.stdout.write(JSON.stringify({
          flat: hits.map((h) => h.url),
          first_down: nav.move(-1, 3, 1),
          first_up: nav.move(-1, 3, -1),
          across_groups: nav.move(1, 3, 1),
          wraps_down: nav.move(2, 3, 1),
          wraps_up: nav.move(0, 3, -1),
          empty: nav.move(-1, 0, 1),
          enter_picked: nav.target(hits, 2),
          enter_unpicked: nav.target(hits, -1),
          enter_nothing: nav.target([], -1),
          keys: ["ArrowDown", "ArrowUp", "Enter", "Escape", "a"].map((key) => nav.keyAction({ key })),
          cmd_k: nav.opensOverlay({ key: "k", metaKey: true }, true),
          ctrl_k: nav.opensOverlay({ key: "K", ctrlKey: true }, false),
          slash: nav.opensOverlay({ key: "/" }, false),
          slash_typing: nav.opensOverlay({ key: "/" }, true),
          plain_k: nav.opensOverlay({ key: "k" }, false),
        }));
      JS
    )
  }

  it "walks the hits in drawn order, across groups" do
    expect(result["flat"]).to eq(["/a", "/b", "/c"])
    expect(result["across_groups"]).to eq(2)
  end

  it "starts at either end and wraps" do
    expect(result.values_at("first_down", "first_up")).to eq([0, 2])
    expect(result.values_at("wraps_down", "wraps_up")).to eq([0, 2])
    expect(result["empty"]).to eq(-1)
  end

  it "opens the picked hit, else the first" do
    expect(result.values_at("enter_picked", "enter_unpicked", "enter_nothing")).to eq(["/c", "/a", nil])
  end

  it "maps the box's keys" do
    expect(result["keys"]).to eq(["down", "up", "open", "close", nil])
  end

  it "opens on Cmd/Ctrl+K anywhere and on / only when not typing" do
    expect(result.values_at("cmd_k", "ctrl_k", "slash")).to all(be(true))
    expect(result.values_at("slash_typing", "plain_k")).to all(be(false))
  end
end
