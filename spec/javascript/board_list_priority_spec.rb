require "rails_helper"

# A board list's priorities (Buddy::BoardList) as the pet shows them: the newest
# high item said in its speech bubble, the newest very high one in its thought
# bubble while it shouts, until that item is checked off.
RSpec.describe "Board list priorities" do
  let(:result) { JsRunner.output("spec/javascript/board_list_priority_runner.js") }

  it "says the newest open high item, looking surprised, without shouting" do
    expect(result["high"]).to eq("speech" => "Chairs", "speechHidden" => false, "thoughtHidden" => true)
    expect(result["high_shouts"]).to be(false)
    expect(result["high_face"]).to eq("surprised")
  end

  it "dreams of the newest very high item and shouts about it" do
    expect(result["very_high"]).to eq("thought" => "Wallet", "thoughtHidden" => false, "speech" => "Chairs")
    expect(result["shouting"]).to be(true)
    expect(result["shout_faces"]).to eq(["playful", "surprised"])
  end

  it "keeps shouting when the pet is tapped" do
    expect(result["after_tap"]).to eq("thought" => "Wallet", "shouting" => true)
  end

  it "stops once the item is checked off, and the pet settles" do
    expect(result["checked_off"]).to eq("thoughtHidden" => true, "shouting" => false, "rested" => true)
    expect(result["all_done"]).to eq("speechHidden" => true, "thoughtHidden" => true, "highFace" => nil)
  end

end
