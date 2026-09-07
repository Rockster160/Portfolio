require "rails_helper"

# Holding + or − on a counter card opens a sheet you type an amount into,
# instead of tapping once per unit. Several numbers at a time are summed,
# and the line above the field says where the counter is, what the numbers
# come to, and where it lands — `43 + 18 = 61` — so the result is visible
# before it's committed to.
RSpec.describe "Counter bulk adjust (JS-side)" do
  let(:result) { JsRunner.output("spec/javascript/counter_bulk_runner.js") }

  describe "the preview line" do
    it "reads original + sum = new value" do
      expect(result.dig("single", "sum")).to eq("43 + 18 = 61")
    end

    it "sums several numbers into one adjustment" do
      expect(result.dig("several", "sum")).to eq("43 + 11 = 54")
    end

    it "spells out the terms when there is more than one" do
      expect(result.dig("several", "terms")).to eq("5 + 8 − 2")
      expect(result.dig("single", "terms")).to eq("")
    end

    it "takes them separated by spaces, commas or new lines alike" do
      expect(result["newlines"]).to eq(result["several"])
    end

    it "flips the operator when the numbers come to less than nothing" do
      expect(result.dig("all_negative", "sum")).to eq("43 − 13 = 30")
    end

    # Nothing typed yet is not an adjustment of zero — it's the counter as
    # it stands, and there is nothing to apply.
    it "shows the current value alone before anything is typed" do
      expect(result["opened_empty"]).to eq(
        "sum" => "43", "idle" => true, "applyDisabled" => true,
      )
    end

    it "has nothing to apply when the numbers cancel out" do
      expect(result.dig("nets_to_zero", "sum")).to eq("43 + 0 = 43")
      expect(result.dig("nets_to_zero", "applyDisabled")).to be(true)
    end

    it "ignores text that carries no number" do
      expect(result["junk"]).to eq("sum" => "43", "terms" => "", "applyDisabled" => true)
    end
  end

  describe "applying" do
    # One call, carrying the total as a raw `amount`. Sent as `by` the
    # server would multiply it by the counter's step — this one's step is
    # 3, so 11 would land as 33.
    it "sends a single increment carrying the total as a raw amount" do
      expect(result["applied"]).to eq([{ "id" => 7, "by" => nil, "amount" => 11 }])
    end

    it "closes the sheet" do
      expect(result["closed_on_apply"]).to be(true)
    end
  end

  # Which button was held decides the direction, so subtracting 18 is
  # typing "18" — not remembering to type "-18".
  describe "held on the − button" do
    it "says what it will do" do
      expect(result["minus_title"]).to eq("Subtract from Rocco")
      expect(result["opened_title"]).to eq("Add to Rocco")
    end

    it "subtracts what was typed" do
      expect(result.dig("minus_single", "sum")).to eq("43 − 18 = 25")
    end

    it "sends the total as a negative amount" do
      expect(result["minus_applied"]).to eq([{ "id" => 7, "by" => nil, "amount" => -12 }])
    end

    # A negative among them goes the OTHER way — back up — rather than
    # subtracting twice.
    it "reads a negative in the list as an addition" do
      expect(result.dig("minus_with_negative", "sum")).to eq("43 − 12 = 31")
      expect(result.dig("minus_with_negative", "terms")).to eq("−18 + 6")
    end
  end

  it "does not open on a timer that has no value to adjust" do
    expect(result["opened_on_countdown"]).to be(false)
  end

  describe "reading the numbers out of the text" do
    it "takes any separator, and none at all" do
      expect(result["parse"]).to include(
        "spaces" => [5, 8, 2],
        "commas" => [5, 8, 2],
        "mixed"  => [5, 8, -2],
        "run_on" => [5, -2],
      )
    end

    it "ignores everything that isn't a number" do
      expect(result.dig("parse", "words")).to eq([5])
      expect(result.dig("parse", "empty")).to eq([])
    end
  end
end
