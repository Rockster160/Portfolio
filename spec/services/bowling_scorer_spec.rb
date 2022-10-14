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

  describe "#params_to_attributes" do
    let(:convert) { BowlingScorer.params_to_attributes(frame_params) }

    context "with an open frame" do
      let(:frame_params) {
        {
          frame_num: "1",
          throw1_remaining: "[5,6,8,9,10]",
          throw2_remaining: "[10]",
          throw3_remaining: nil,
        }
      }

      specify {
        expect(convert).to eq({
          frame_num: "1",
          spare: false,
          strike: false,
          split: false,
          strike_point: nil,
          throw1: 5,
          throw2: 4,
          throw3: nil,
          throw1_remaining: [5,6,8,9,10],
          throw2_remaining: [10],
          throw3_remaining: nil,
        })
      }
    end

    context "with a spare" do
      let(:frame_params) {
        {
          frame_num: "1",
          throw1_remaining: "[5,6,8,9,10]",
          throw2_remaining: "[]",
          throw3_remaining: nil,
        }
      }

      specify {
        expect(convert).to eq({
          frame_num: "1",
          spare: true,
          strike: false,
          split: false,
          strike_point: nil,
          throw1: 5,
          throw2: 5,
          throw3: nil,
          throw1_remaining: [5,6,8,9,10],
          throw2_remaining: [],
          throw3_remaining: nil,
        })
      }
    end

    context "with a strike" do
      let(:frame_params) {
        {
          frame_num: "1",
          throw1_remaining: "[]",
          throw2_remaining: nil,
          throw3_remaining: nil,
        }
      }

      specify {
        expect(convert).to eq({
          frame_num: "1",
          spare: false,
          strike: true,
          split: false,
          strike_point: nil,
          throw1: 10,
          throw2: nil,
          throw3: nil,
          throw1_remaining: [],
          throw2_remaining: nil,
          throw3_remaining: nil,
        })
      }
    end

    describe "without setting pins" do
      context "with an open frame" do
        let(:frame_params) {
          {
            frame_num: "1",
            throw1: "5",
            throw2: "4",
            throw3: ""
          }
        }

        specify {
          expect(convert).to eq({
            frame_num: "1",
            spare: false,
            strike: false,
            split: false,
            strike_point: nil,
            throw1: 5,
            throw2: 4,
            throw3: nil,
            throw1_remaining: nil,
            throw2_remaining: nil,
            throw3_remaining: nil,
          })
        }
      end

      context "with a spare" do
        let(:frame_params) {
          {
            frame_num: "1",
            throw1: "5",
            throw2: "/",
            throw3: ""
          }
        }

        specify {
          expect(convert).to eq({
            frame_num: "1",
            spare: true,
            strike: false,
            split: false,
            strike_point: nil,
            throw1: 5,
            throw2: 5,
            throw3: nil,
            throw1_remaining: nil,
            throw2_remaining: nil,
            throw3_remaining: nil,
          })
        }
      end

      context "with a strike" do
        let(:frame_params) {
          {
            frame_num: "1",
            throw1: "X",
            throw2: "",
            throw3: ""
          }
        }

        specify {
          expect(convert).to eq({
            frame_num: "1",
            spare: false,
            strike: true,
            split: false,
            strike_point: nil,
            throw1: 10,
            throw2: nil,
            throw3: nil,
            throw1_remaining: nil,
            throw2_remaining: nil,
            throw3_remaining: nil,
          })
        }
      end
    end
  end
end
