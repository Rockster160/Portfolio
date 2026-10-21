require "rails_helper"

# A Jil select that also takes free text (`face:["sleeping" "thinking" "wave" *]`):
# the choices are offered, and anything else typed into "<other>" is kept.
RSpec.describe "Jil free-text select" do
  let(:result) { JsRunner.output("spec/javascript/jil_free_text_select_runner.js") }

  it "reads a trailing * as 'or type your own', and leaves other selects alone" do
    expect(result["free"]).to eq("options" => %w[sleeping thinking wave], "freeText" => true)
    expect(result["fixed"]).to eq("options" => %w[seconds minutes], "freeText" => false)
  end

  it "loads a choice into the select, and anything else into the typed box" do
    expect(result["known"]).to eq("select" => "thinking", "otherHidden" => true)
    expect(result["typed"]).to eq("select" => "<other>", "other" => "nerd", "otherHidden" => false)
  end
end
