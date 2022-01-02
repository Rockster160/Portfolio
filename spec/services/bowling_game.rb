RSpec.describe BowlingScorer do
  describe "#split?" do
    let(:split_check) { BowlingScorer.split?(pins) }

    context "with a near split" do
      let(:pins) { [4, 5] }

      it "returns true" do
        expect(split_check).to be(true)
      end
    end

    context "with a wide split" do
      let(:pins) { [7, 10] }

      it "returns true" do
        expect(split_check).to be(true)
      end
    end

    context "with pins next to each other" do
      let(:pins) { [6, 10] }

      it "returns false" do
        expect(split_check).to be(false)
      end
    end

    context "with the head pin intact" do
      let(:pins) { [1, 10] }

      it "returns false" do
        expect(split_check).to be(false)
      end
    end
  end
end
