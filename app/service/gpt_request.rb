# One chat completion, paid for by whichever OpenAI key the caller hands in.
# Jil's GPT.connection resolves that key from the user's own secrets; this
# never reaches for the server's key.
class GPTRequest
  MODEL = "gpt-5.4-mini".freeze
  TIMEOUT_SECONDS = 60

  # json_object mode refuses a request whose messages never say "JSON".
  JSON_INSTRUCTION = "Respond with a single JSON object and nothing else.".freeze

  Error = Class.new(StandardError)

  def self.call(key, input, instructions: nil, json: false)
    new(key).call(input, instructions: instructions, json: json)
  end

  def initialize(key)
    @key = key
  end

  def call(input, instructions: nil, json: false)
    raise Error, "No OpenAI key given" if @key.blank?

    messages = []
    messages << { role: :system, content: instructions.to_s } if instructions.present?
    messages << { role: :system, content: JSON_INSTRUCTION } if json
    messages << { role: :user, content: input.to_s }

    parameters = { model: MODEL, messages: messages }
    parameters[:response_format] = { type: :json_object } if json

    text = client.chat(parameters: parameters).dig("choices", 0, "message", "content").to_s
    json ? parse(text) : text
  rescue Faraday::Error => e
    raise Error, "OpenAI request failed: #{e.message}"
  end

  private

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
