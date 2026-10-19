require "rails_helper"

RSpec.describe Buddy::FormFields do
  let(:field) {
    {
      key: "Who did it?", type: :chips, choices: %w[Rockster160 Alchemibluum],
      colors: { Rockster160: "#0160FF" },
    }
  }

  it "keeps a chips field and its colors" do
    expect(described_class.normalize([field]).sole).to include(
      type: :chips, choices: %w[Rockster160 Alchemibluum], colors: { "Rockster160" => "#0160FF" },
    )
  end

  it "takes one of the chips and refuses anything else" do
    expect(described_class.collect([field], { "Who did it?" => "alchemibluum" })).to eq(
      [{ "Who did it?" => "Alchemibluum" }, []],
    )
    _, errors = described_class.collect([field], { "Who did it?" => "Eve" })
    expect(errors.sole).to match(/isn't one of the options/)
  end
end
