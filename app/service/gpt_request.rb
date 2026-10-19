# One chat completion, paid for by whichever OpenAI key the caller hands in.
# Jil's GPT.connection resolves that key from the user's own secrets; this
# never reaches for the server's key.
class GPTRequest
  MODEL = "gpt-5.4-mini".freeze
  TIMEOUT_SECONDS = 60

  # json_object mode refuses a request whose messages never say "JSON".
  JSON_INSTRUCTION = "Respond with a single JSON object and nothing else.".freeze

  Error = Class.new(StandardError)

  def self.call(key, input, instructions: nil, json: false, user: nil)
    new(key, user: user).call(input, instructions: instructions, json: json)
  end

  # `user` is who the spend is written down against; without one the call is
  # made but not recorded.
  def initialize(key, user: nil)
    @key = key
    @user = user
  end

  def call(input, instructions: nil, json: false)
    raise Error, "No OpenAI key given" if @key.blank?

    messages = []
    messages << { role: :system, content: instructions.to_s } if instructions.present?
    messages << { role: :system, content: JSON_INSTRUCTION } if json
    messages << { role: :user, content: input.to_s }

    parameters = { model: MODEL, messages: messages }
    parameters[:response_format] = { type: :json_object } if json

    response = client.chat(parameters: parameters)
    record_usage(response["usage"])
    text = response.dig("choices", 0, "message", "content").to_s
    json ? parse(text) : text
  rescue Faraday::Error => e
    raise Error, "OpenAI request failed: #{e.message}"
  end

  private

  # Chat completions name the counts differently from the Responses API that
  # BuddyUsage was written for. Priced on MODEL rather than the reply's model,
  # which carries a dated suffix the price table doesn't list.
  def record_usage(usage)
    return if @user.nil? || usage.blank?

    BuddyUsage.record!({
      model: MODEL,
      usage: {
        input_tokens:        usage["prompt_tokens"],
        cached_input_tokens: usage.dig("prompt_tokens_details", "cached_tokens"),
        output_tokens:       usage["completion_tokens"],
        reasoning_tokens:    usage.dig("completion_tokens_details", "reasoning_tokens"),
      },
    }, user: @user, kind: :jil)
  rescue StandardError => e
    Rails.logger.warn("[GPTRequest] usage record failed: #{e.class}: #{e.message}")
  end

  def client
    ::OpenAI::Client.new(access_token: @key, request_timeout: TIMEOUT_SECONDS)
  end

  def parse(text)
    parsed = JSON.parse(text)
    raise Error, "GPT returned #{parsed.class}, not an object: #{text.truncate(200)}" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise Error, "GPT returned invalid JSON: #{text.truncate(200)}"
  end
end
