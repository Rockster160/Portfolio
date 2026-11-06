require "rails_helper"

# A ring running out sounds once across every screen showing it.
RSpec.describe "Ring sound claims" do
  let(:result) { JsRunner.output("spec/javascript/ring_claim_runner.js") }

  it "plays on one screen when two see the same ring run out" do
    expect(result["two_screens"]).to eq(["wake@0"])
  end

  it "stays quiet on a screen that reloads while the ring is still overdue" do
    expect(result["after_reload"]).to eq([])
  end

  it "plays the five-minute repeat once" do
    expect(result["repeat"]).to eq(["wake@300"])
  end

  it "plays a ring marked once when it runs out and never at the repeats" do
    expect(result["once"]).to eq(["nap@0"])
  end

  it "never claims from a hidden page" do
    expect(result["hidden"]).to eq("played" => [], "claims" => 0)
  end

  it "plays once anyway when the server can't be reached" do
    expect(result["offline"]).to eq(["nap@31"])
  end
end
