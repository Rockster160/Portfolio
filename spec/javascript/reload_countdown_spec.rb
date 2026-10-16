require "rails_helper"

# A wall screen (kiosk or board) taking an update without pulling the page out
# from under someone using it: a short countdown that any touch restarts, held
# while something is open or the network is gone, and a pause that holds it for
# good.
RSpec.describe "Wall screen reload countdown" do
  let(:result) { JsRunner.output("spec/javascript/reload_countdown_runner.js") }

  it "stays out of sight until an update is waiting" do
    expect(result["hidden_before_start"]).to be(true)
    expect(result["shown_on_start"]).to be(true)
    expect(result["first_text"]).to eq("10")
  end

  it "goes back to the start whenever someone touches the screen" do
    expect(result["after_four"]).to eq("6")
    expect(result["after_touch"]).to eq("10")
  end

  it "waits while something is open over the screen, or the network is gone" do
    expect(result["held_reloads"]).to eq(0)
    expect(result["held_text"]).to eq("10")
    expect(result["offline_reloads"]).to eq(0)
  end

  it "holds for good when paused" do
    expect(result["paused_reloads"]).to eq(0)
    expect(result["paused_text"]).to eq("10")
    expect(result["paused_flag"]).to eq("true")
  end

  it "stays paused through the next deploy" do
    expect(result["next_deploy_paused"]).to eq("true")
    expect(result["next_deploy_reloads"]).to eq(0)
  end

  it "reloads once the count runs out, and not a second sooner" do
    expect(result["one_short_reloads"]).to eq(0)
    expect(result["at_zero_reloads"]).to eq(1)
  end
end
