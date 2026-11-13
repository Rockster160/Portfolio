require "rails_helper"

# The board's status rings do what each ring's broadcast says - a hush, its
# own colour - with nothing keyed to what any ring is for. A ring running out is
# silent: a sound comes from the task that sends it to the board.
RSpec.describe "Board status rings" do
  let(:result) { JsRunner.output("spec/javascript/board_rings_runner.js") }

  it "listens on the board's own channel" do
    expect(result["channel"]).to eq("board-rings")
  end

  it "plays nothing and claims nothing when a ring runs out, even one naming a sound" do
    expect(result["overdue"]).to eq("played" => [], "requests" => [])
  end

  it "greys the other rings under a hush and keeps a ring's own colour" do
    expect(result["hushed"]).to eq(
      "a" => true, "hush" => false, "own" => false,
      "own_color" => "#800000", "own_flag" => "true"
    )
  end

  it "asks the feed again when the hush ends" do
    expect(result["after_hush"]).to eq("refreshes" => 1, "a" => false, "own_flag" => nil)
  end

  it "shows nothing from a feed aimed elsewhere" do
    expect(result["elsewhere"]).to eq("rings" => 0, "hidden" => true)
  end
end
