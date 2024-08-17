RSpec.describe Jil::Parser do
  include ActiveJob::TestHelper
  let(:parsed) { described_class.from_code(code) }
  let(:code) { "" }

  context "full-example" do
    let(:code) { jil_fixture(:garage_cell) }

    it "parses" do
      expect(parsed.length).to eq(15)
      expect(parsed.all? { |line| line.is_a?(Jil::Parser)}).to be(true)

      if_block = parsed[10]
      expect(if_block.methodname).to eq(:if)
      expect(if_block.args.length).to eq(3)
      if_condition, if_do, if_else = if_block.args
      expect(if_condition.first.args).to eq(["timeDiff", "<", "hour"])
      expect(if_else).to eq([])
      # Maybe add more checks?
    end
  end
end
