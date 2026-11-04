require "rails_helper"

# A Byte form's checkbox label, and the repaint a refresh sends back.
RSpec.describe "Byte form refresh" do
  let(:result) { JsRunner.output("spec/javascript/byte_form_refresh_runner.js") }

  it "toggles the checkbox from its label" do
    expect(result["labelToggled"]).to be(true)
  end

  it "repaints with the new value while the refresh button holds focus, keeping what was ticked" do
    expect(result["afterButton"]).to eq("calories" => "1200", "checked" => true)
  end

  it "doesn't repaint under a box being typed in" do
    expect(result["whileTyping"]).to eq("1200")
  end
end
