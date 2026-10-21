require "rails_helper"

# The board's status rings do what each ring's broadcast says - its sound, a
# hush, its own colour - with nothing keyed to what any ring is for.
RSpec.describe "Board status rings" do
  let(:result) { JsRunner.output("spec/javascript/board_rings_runner.js") }

  it "listens on the board's own channel" do
    expect(result["channel"]).to eq("board-rings")
  end

  it "plays a ring's own sound when it runs out, and nothing for a ring without one" do
    expect(result["overdue_played"]).to eq(["nap"])
  end

  it "greys the other rings under a hush, keeps a ring's own colour, and holds sounds" do
    expect(result["hushed"]).to eq(
      "a" => true, "hush" => false, "own" => false,
      "own_color" => "#800000", "own_flag" => "true", "played" => []
    )
  end

  it "asks the feed again when the hush ends" do
    expect(result["after_hush"]).to eq("refreshes" => 1, "a" => false, "own_flag" => nil)
  end

  it "shows nothing from a feed aimed elsewhere" do
    expect(result["elsewhere"]).to eq("rings" => 0, "hidden" => true)
  end
end
