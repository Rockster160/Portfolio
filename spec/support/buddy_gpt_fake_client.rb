# Stand-in for Buddy::GPT::Client so turn-level specs never touch the network.
#
# Scripted with one entry per round the model would take, so a round-trip
# (get_context, then answer) is expressed as two entries. Each entry mirrors the
# real client's return shape and yields the same semantic events in order, which
# is what lets Buddy::GPT::Turn be exercised end to end offline.
#
#   client = FakeBuddyClient.new([
#     { text: "One sec.", tool_calls: [{ name: :get_context, call_id: "c1", arguments: { "sections" => ["chores_all"] } }] },
#     { text: "You've got three left." },
#   ])
#
# An action turn is a single round, with the prose riding on the call's `reply`
# field the way production works:
#
#   FakeBuddyClient.new([
#     { tool_calls: [{ name: :log_event, arguments: { "name" => "Coffee", "reply" => "Nice, logged." } }] },
#   ])
#
# Every request it received is kept on `#calls` so specs can assert on the
# instructions, input array, and tool schemas that were actually sent.
class FakeBuddyClient
  Request = Struct.new(:instructions, :input, :tools, :deadline, keyword_init: true)

  # A real model slug by default so Buddy::GPT::Pricing resolves a rate and cost
  # assertions exercise the real math. Override per instance to test the
  # unknown-model path.
  DEFAULT_MODEL = "gpt-5.4-mini".freeze

  # Stands in for what the API reports on response.completed. Mirrors the real
  # relationships: input_tokens INCLUDES cached, output_tokens INCLUDES reasoning.
  DEFAULT_USAGE = {
    input_tokens:        1_000,
    cached_input_tokens: 800,
    output_tokens:       100,
    reasoning_tokens:    20,
    total_tokens:        1_100,
  }.freeze

  attr_reader :calls, :model

  def initialize(rounds, model: DEFAULT_MODEL)
    @rounds = Array(rounds)
    @model  = model
    @calls  = []
    @index  = 0
  end

  def stream(instructions:, input:, tools: [], deadline: nil, &block)
    @calls << Request.new(instructions: instructions, input: input, tools: tools, deadline: deadline)

    round = @rounds[@index] || { text: "" }
    @index += 1

    return failure(round) if round[:error]

    text       = round[:text].to_s
    tool_calls = normalize(round[:tool_calls])

    # Mirror the real ordering: tool calls surface as their items complete,
    # which for a leading set is before any prose has streamed.
    tool_calls.each { |call| block&.call(call.merge(type: :tool_call)) }
    stream_text(text, &block)

    {
      ok:          true,
      text:        text,
      tool_calls:  tool_calls,
      response_id: "resp_fake_#{@index}",
      error:       nil,
      model:       @model,
      usage:       round.fetch(:usage, DEFAULT_USAGE),
    }
  end

  private

  # Chunked so throttling and partial-render behavior get exercised rather than
  # arriving as one atomic delta.
  def stream_text(text, &block)
    return if text.empty?

    text.chars.each_slice(24) { |chunk| block&.call({ type: :text_delta, text: chunk.join }) }
  end

  # A failed response can still have consumed tokens, so usage is honored here
  # too — pass `usage: nil` to model an outright rejected request, which bills
  # nothing.
  def failure(round)
    {
      ok:          false,
      text:        "",
      tool_calls:  [],
      response_id: nil,
      error:       round[:error],
      model:       @model,
      usage:       round.fetch(:usage, DEFAULT_USAGE),
    }
  end

  def normalize(calls)
    Array(calls).each_with_index.map { |call, i|
      {
        name:      call[:name].to_sym,
        call_id:   call[:call_id] || "call_fake_#{@index}_#{i}",
        arguments: (call[:arguments] || {}).transform_keys(&:to_s),
      }
    }
  end
end
