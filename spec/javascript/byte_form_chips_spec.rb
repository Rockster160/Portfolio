require "rails_helper"

# A `chips` prompt question in a Buddy thread: one radio per choice so only one
# can be picked, each carrying its own color, and the picked one is what posts.
RSpec.describe "Byte form chips" do
  let(:result) { JsRunner.output("spec/javascript/byte_form_chips_runner.js") }
  let(:chips) { result["chips"] }

  it "draws one radio per choice, in one group" do
    expect(chips.pluck("text")).to eq(%w[Rockster160 Eve Alchemibluum])
    expect(chips.pluck("type").uniq).to eq(["radio"])
    expect(chips.pluck("group").uniq.length).to eq(1)
  end

  it "colors the chips that have a color and leaves the rest to the accent" do
    expect(chips.pluck("color")).to eq(["#0160FF", nil, "#A082D9"])
  end

  it "opens on the default" do
    expect(chips.select { |c| c["checked"] }.pluck("text")).to eq(["Eve"])
  end

  it "posts the chip that was tapped" do
    expect(result["posted"].sole["body"]["form"]).to eq("Who did it?" => "Alchemibluum")
  end
end
