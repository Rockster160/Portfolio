require "rails_helper"

# A mood held from Jil (Buddy.mood) on the board: no bubble, the pet just wears
# it - one face per pet - for as long as it stands.
RSpec.describe "Board moods" do
  let(:result) { JsRunner.output("spec/javascript/board_mood_runner.js") }

  it "holds a mood aimed at the board, with no bubble" do
    expect(result["held"]).to eq(
      "board-mood:busy" => { "face" => { "byte" => "nerd", "moss" => "happy" }, "strength" => 60 },
    )
    expect(result["bubbleHidden"]).to be(true)
  end

  it "keeps it beside an alert, which wears its own mood's faces" do
    expect(result["with_alert"]["bubble"]).to eq("Gate open")
    expect(result["with_alert"]["held"]).to include(
      "board-mood:busy" => hash_including("strength" => 60),
      "board-alert"     => hash_including("face" => { "byte" => "sleeping" }),
    )
  end

  it "lets it go once resolved" do
    expect(result["resolved"]).to eq({})
  end
end
