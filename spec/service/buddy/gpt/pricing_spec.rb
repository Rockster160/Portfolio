require "rails_helper"

RSpec.describe Buddy::GPT::Pricing do
  def usage(input:, cached: 0, output: 0, reasoning: 0)
    {
      input_tokens:        input,
      cached_input_tokens: cached,
      output_tokens:       output,
      reasoning_tokens:    reasoning,
      total_tokens:        input + output,
    }
  end

  describe ".cost_micros" do
    it "bills uncached input, cached input, and output at their own rates" do
      # gpt-5.4-mini: $0.75 / $0.075 / $4.50 per 1M.
      #   200k fresh input  -> 200_000 / 1e6 * 0.75  = $0.15
      #   800k cached input -> 800_000 / 1e6 * 0.075 = $0.06
      #   100k output       -> 100_000 / 1e6 * 4.50  = $0.45
      #   total $0.66 = 660_000 micros
      cost = described_class.cost_micros(
        usage(input: 1_000_000, cached: 800_000, output: 100_000), model: "gpt-5.4-mini"
      )

      expect(cost).to eq(660_000)
    end

    it "treats input_tokens as INCLUSIVE of cached tokens" do
      # The whole input is cached, so nothing bills at the full input rate.
      # Getting this wrong overstates Buddy's cost roughly tenfold, since the
      # stable prompt prefix caches on nearly every turn.
      all_cached = described_class.cost_micros(
        usage(input: 1_000_000, cached: 1_000_000), model: "gpt-5.4-mini"
      )
      none_cached = described_class.cost_micros(
        usage(input: 1_000_000, cached: 0), model: "gpt-5.4-mini"
      )

      expect(all_cached).to eq(75_000)    # 1M @ $0.075
      expect(none_cached).to eq(750_000)  # 1M @ $0.75
    end

    it "does not double-charge reasoning tokens, which output_tokens already includes" do
      with_reasoning    = usage(input: 0, output: 100_000, reasoning: 90_000)
      without_reasoning = usage(input: 0, output: 100_000, reasoning: 0)

      expect(described_class.cost_micros(with_reasoning, model: "gpt-5.4-mini"))
        .to eq(described_class.cost_micros(without_reasoning, model: "gpt-5.4-mini"))
    end

    it "never returns a negative cost when cached exceeds input" do
      cost = described_class.cost_micros(usage(input: 100, cached: 500), model: "gpt-5.4-mini")

      expect(cost).to be >= 0
    end

    it "returns zero for an unrecognized model rather than guessing a rate" do
      cost = described_class.cost_micros(
        usage(input: 1_000_000, output: 1_000_000), model: "gpt-9-imaginary"
      )

      expect(cost).to eq(0)
      expect(described_class.known_model?("gpt-9-imaginary")).to be(false)
    end

    it "returns zero when there is no usage payload" do
      expect(described_class.cost_micros(nil, model: "gpt-5.4-mini")).to eq(0)
    end

    it "prices a realistic Buddy turn at a fraction of a cent" do
      # ~23k fixed prefix (prompt + tool schemas) mostly served from cache, plus
      # a short reply:
      #     500 fresh   @ $0.75/M  = $0.000375
      #  23,000 cached  @ $0.075/M = $0.001725
      #     120 output  @ $4.50/M  = $0.000540
      #                              $0.002640
      cost = described_class.cost_micros(
        usage(input: 23_500, cached: 23_000, output: 120), model: "gpt-5.4-mini"
      )

      expect(cost).to eq(2_640)
      expect(described_class.format_micros(cost)).to eq("$0.0026")
    end

    it "shows what the prompt cache is worth on Buddy's fixed prefix" do
      # Same turn with a cold cache. This ~7x gap is why the ~9.6k tokens of
      # tool schemas are affordable to send in full on every turn, and why a
      # persistently low cache_hit_rate is worth alerting on.
      warm = described_class.cost_micros(
        usage(input: 23_500, cached: 23_000, output: 120), model: "gpt-5.4-mini"
      )
      cold = described_class.cost_micros(
        usage(input: 23_500, cached: 0, output: 120), model: "gpt-5.4-mini"
      )

      expect(cold).to be > (warm * 6)
    end
  end

  describe ".format_micros" do
    it "shows four decimals below a dollar so a single turn is not rounded away" do
      expect(described_class.format_micros(2_500)).to eq("$0.0025")
    end

    it "shows two decimals at a dollar and above" do
      expect(described_class.format_micros(12_345_678)).to eq("$12.35")
    end
  end

  describe "RATES" do
    it "covers the models Buddy actually calls" do
      expect(described_class).to be_known_model(Buddy::GPT::Client::DEFAULT_MODEL)
      expect(described_class).to be_known_model(Buddy::Compactor::MODEL)
    end
  end
end
