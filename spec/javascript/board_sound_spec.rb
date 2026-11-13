require "rails_helper"

# A board plays the notes a task sent it, as sent, and nothing while it is
# shushed. No tune lives in the browser any more.
RSpec.describe "Board sound" do
  let(:result) { JsRunner.output("spec/javascript/board_sound_runner.js") }

  it "plays the notes it was sent, rests included" do
    expect(result["played"]).to eq([[[400, 392, 0.9, "sine"], [200, 0, 0, nil], [600, 262, 0.87, "sine"]]])
  end

  it "plays nothing for a bare name, an empty sound, or none" do
    expect(result["nothing_to_play"]).to eq([])
  end

  it "stays quiet while the board is shushed" do
    expect(result["muted"]).to eq([])
  end
end
