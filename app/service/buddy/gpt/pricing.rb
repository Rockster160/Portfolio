module Buddy
  module GPT
    # Token pricing for the models Buddy calls, and the cost math over a
    # Responses-API `usage` payload.
    #
    # Money is handled in integer MICRO-DOLLARS (millionths of a dollar) end to
    # end. A single cheap turn runs a few hundred micros, so this has plenty of
    # resolution, and integers mean summing a month of turns can't drift the way
    # accumulated floats would.
    module Pricing
      module_function

      # USD per 1,000,000 tokens, from OpenAI's published standard-tier pricing.
      # `cached_input` is the discounted rate for prompt-prefix cache hits, which
      # is most of Buddy's input: the tool schemas and system prompt are a stable
      # ~23k-token prefix on every turn.
      #
      # Verified 2026-07-29. These are list prices and they move — when a rate
      # changes, historical BuddyUsage rows keep the cost computed at the time,
      # so editing this table never rewrites the past.
      RATES = {
        "gpt-5.4-mini"  => { input: 0.75,  cached_input: 0.075, output: 4.50 },
        "gpt-5.4-nano"  => { input: 0.20,  cached_input: 0.02,  output: 1.25 },
        "gpt-5.4"       => { input: 2.50,  cached_input: 0.25,  output: 15.00 },
        "gpt-5.6-luna"  => { input: 1.00,  cached_input: 0.10,  output: 6.00 },
        "gpt-5.6-terra" => { input: 2.50, cached_input: 0.25, output: 15.00 },
        "gpt-5.6-sol"   => { input: 5.00, cached_input: 0.50, output: 30.00 },
      }.freeze

      # Billed as ordinary input/output tokens, so an unknown model costs 0
      # rather than guessing. A zero row with a real token count is a visible
      # signal that RATES needs an entry; a guessed rate would hide that.
      UNKNOWN_RATE = { input: 0.0, cached_input: 0.0, output: 0.0 }.freeze

      MICROS_PER_DOLLAR = 1_000_000
      TOKENS_PER_UNIT   = 1_000_000

      def rate_for(model)
        RATES[model.to_s] || UNKNOWN_RATE
      end

      def known_model?(model)
        RATES.key?(model.to_s)
      end

      # `usage` is the normalized hash from Buddy::GPT::Client (see
      # Client#extract_usage), NOT the raw API payload.
      #
      # Two things the API's field names make easy to get wrong:
      #   * `input_tokens` INCLUDES cached tokens, so the uncached portion is
      #     the difference. Billing them both at the full rate would overstate
      #     Buddy's cost by roughly an order of magnitude, since the stable
      #     prompt prefix caches on nearly every turn.
      #   * `output_tokens` already INCLUDES reasoning tokens, and reasoning is
      #     billed at the output rate. There is no separate reasoning charge to
      #     add; reasoning_tokens is recorded for visibility only.
      def cost_micros(usage, model:)
        return 0 if usage.blank?

        rate   = rate_for(model)
        cached = usage[:cached_input_tokens].to_i
        fresh  = [usage[:input_tokens].to_i - cached, 0].max
        output = usage[:output_tokens].to_i

        dollars = ((fresh * rate[:input]) + (cached * rate[:cached_input]) + (output * rate[:output])) / TOKENS_PER_UNIT.to_f
        (dollars * MICROS_PER_DOLLAR).round
      end

      # "$0.0182" — enough decimals that a single turn isn't rounded to nothing.
      # Above a dollar, two decimals is what people actually want to read.
      def format_micros(micros)
        dollars = micros.to_i / MICROS_PER_DOLLAR.to_f
        dollars >= 1 ? format("$%.2f", dollars) : format("$%.4f", dollars)
      end
    end
  end
end
