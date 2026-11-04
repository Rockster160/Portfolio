require "rails_helper"

# A Byte form already on screen, repainted by the server: what a push may
# change, what it has to leave alone, and what the refresh button replaces.
RSpec.describe "Byte form push" do
  let(:result) { JsRunner.output("spec/javascript/byte_form_push_runner.js") }

  it "toggles a checkbox from its label" do
    expect(result["labelTicks"]).to be(true)
  end

  it "fills in what nobody touched and keeps what they changed" do
    expect(result["push"]).to eq(
      "Calories" => "900", "Caffeine" => "0", "Notes" => "Sausage Rolls", "Add to Meal Builder" => true,
    )
  end

  it "still reaches a box that was only touched, or changed and put back" do
    expect(result["touched"]).to eq(
      "Calories" => "", "Caffeine" => "40", "Notes" => "Sausage Roll", "Add to Meal Builder" => false,
    )
  end

  it "updates the other boxes in place while one has focus, and that one as focus leaves it", :aggregate_failures do
    expect(result["focused"]).to include("Calories" => "1200", "Caffeine" => "")
    expect(result["sameBoxes"]).to be(true)
    expect(result["focusMoved"]).to include("Calories" => "1200", "Caffeine" => "40")
  end

  it "keeps a box typed into after the push, on leaving it and on the next push" do
    expect(result["typedAfter"]).to include("Calories" => "1300", "Notes" => "Ro")
  end

  it "isn't held back by the refresh button having focus" do
    expect(result["buttonFocused"]).to eq("1200")
  end

  it "keeps the fields on screen when the shape changed, and marks the button", :aggregate_failures do
    expect(result["shape"]["values"]).to eq(
      "Calories" => "900", "Caffeine" => "0", "Notes" => "", "Add to Meal Builder" => false,
    )
    expect(result["shape"]["stale"]).to be(true)
  end

  it "replaces the whole form, edits included, from the refresh button", :aggregate_failures do
    expect(result["replaced"]["values"]).to eq(
      "Calories" => "1200", "Caffeine" => "0", "Notes" => "", "Add to Meal Builder" => false, "Hint" => "5 rolls",
    )
    expect(result["replaced"]["stale"]).to be(false)
  end

  it "waits for the button when the fields come in a different order", :aggregate_failures do
    expect(result["reordered"]["keys"]).to eq(["Calories", "Caffeine", "Notes", "Add to Meal Builder"])
    expect(result["reordered"]["stale"]).to be(true)
    expect(result["reordered"]["calories"]).to eq("1200")
  end

  it "lands a new label and small print straight away, focus or not" do
    expect(result["words"]).to eq("label" => "Calories (kcal)", "hint" => "5 rolls - 1200", "stale" => true)
  end
end
