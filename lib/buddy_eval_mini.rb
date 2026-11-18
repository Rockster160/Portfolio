require "net/http"

# Stands in for Buddy::GPT::Client by putting the turn to Claude on the Mac
# Mini, through Byte's /byte/turn: one Claude Code session per turn, so it runs
# on the Mini's Claude login rather than an API key.
#
# The tools are native ones. Byte serves them to the session over MCP, and a
# call ends the round here like any model's would: the harness runs it and the
# next round sends its result back, which is when Claude Code's call returns.
# The session remembers the conversation, so only that first message carries
# what was said before it.
#
#   BUDDY_EVAL_MODEL=claude-haiku-5-5 bx rails "buddy:eval_failures[20]"
#
# Every round is appended to tmp/buddy_eval/mini_rounds.jsonl with its timings:
# `wall_ms` from here, `mini_ms` inside the Mini, `api_ms` the model's own part.
class BuddyEvalMini
  URL     = ENV.fetch("BUDDY_EVAL_MINI_URL", "http://wildcats-mini:8788")
  ROUNDS  = Rails.root.join("tmp/buddy_eval/mini_rounds.jsonl")
  TIMEOUT = 150

  SEPARATOR = "\n\n---\n\n".freeze
  # Where Buddy::Personality's prompt stops being the same from turn to turn.
  # Everything before it is the session's system prompt, so the spare the Mini
  # keeps started matches the next turn; the rest leads the first message.
  MOVING = ["## Right this second", "## Right now"].freeze

  # Claude Code names a served tool after its server, and the prompt names
  # tools bare.
  NAMING = <<~TXT.freeze
    ## Your tools

    Your tools are listed as mcp__buddy__NAME. Wherever these instructions name a tool, they mean
    that one: `remember` is mcp__buddy__remember. A line starting [app] is an instruction from the
    app, not something they said.
  TXT

  class << self
    attr_accessor :open_session
  end

  attr_reader :model

  def initialize(model:, effort: Buddy::GPT::Client::DEFAULT_REASONING_EFFORT)
    @model   = model
    @effort  = effort
    @session = nil
    @seen    = 0
    @round   = 0
    @waiting = false
    # Claude reports model time and cost as running totals for the session.
    @api_ms  = 0
    @cost    = 0.0
  end

  # Every tool goes over in full: there is no second stage to open them in.
  def opens_everything?
    true
  end

  # `deadline` is the API client's; a round here is bounded by TIMEOUT.
  def stream(instructions:, input:, tools: [], deadline: nil) # rubocop:disable Lint/UnusedMethodArgument
    started = Time.current
    fresh   = input[@seen..].to_a
    @seen   = input.length

    if @session.nil?
      steady, moving = split(instructions)
      opened = open!(steady, tools)
      answer = post(action: :say, id: @session, message: opening(moving, fresh))
    elsif @waiting
      answer = post(action: :answer, id: @session, results: results(fresh))
    else
      answer = post(action: :say, id: @session, message: notes(fresh))
    end
    @round += 1
    return failed(answer[:error]) unless answer[:ok]

    log(started, answer, opened)
    parse(answer)
  rescue StandardError => e
    failed("#{e.class}: #{e.message}")
  end

  private

  def split(instructions)
    parts = instructions.split(SEPARATOR)
    at    = parts.index { |part| part.start_with?(*MOVING) } || parts.length
    [parts[0...at].join(SEPARATOR), parts[at..].join(SEPARATOR)]
  end

  # One session per turn. The harness has no "turn over", so a turn's session
  # is closed when the next one opens.
  def open!(steady, tools)
    close(self.class.open_session) if self.class.open_session
    opened = post(
      action: :open,
      system: [steady, NAMING].join(SEPARATOR),
      model:  model,
      effort: @effort,
      tools:  tools,
    )
    raise opened[:error].to_s unless opened[:ok]

    @session = self.class.open_session = opened[:id]
    opened
  end

  def close(id)
    post(action: :close, id: id)
  rescue StandardError
    nil
  end

  def opening(moving, items)
    said   = items.rindex { |item| item[:role]&.to_sym == :user } || items.length
    before = items[0...said].map { |item|
      "#{item[:role].to_sym == :user ? "Them" : "You"}: #{text_of(item)}"
    }
    [
      moving.presence,
      ("Earlier in this conversation:\n#{before.join("\n")}" if before.any?),
      text_of(items[said]),
      notes(items[(said + 1)..].to_a).presence,
    ].compact.join("\n\n")
  end

  # The outputs of the calls the last round handed back. A note the app adds
  # alongside rides on the last of them, as nothing else can reach the model
  # while its calls are out.
  def results(items)
    outputs = items.select { |item| item[:type]&.to_sym == :function_call_output }
    outputs = outputs.map { |item| { id: item[:call_id], output: item[:output].to_s } }
    note    = notes(items)
    outputs.last[:output] += "\n\n#{note}" if note.present? && outputs.any?
    outputs
  end

  def notes(items)
    items.filter_map { |item|
      next if item[:type].present?

      item[:role].to_sym == :developer ? "[app] #{text_of(item)}" : text_of(item)
    }.join("\n\n")
  end

  def text_of(item)
    content = item[:content]
    return content.to_s unless content.is_a?(Array)

    content.map { |part|
      part[:type].to_s == "input_image" ? "[an image]" : part[:text].to_s
    }.join(" ")
  end

  def parse(answer)
    @waiting = answer[:kind].to_s == "calls"
    calls = Array(answer[:calls]).map { |call|
      arguments = call[:arguments].is_a?(Hash) ? call[:arguments].deep_stringify_keys : {}
      { name: call[:name].to_sym, call_id: call[:id], arguments: arguments }
    }
    text = answer[:text].to_s.strip
    {
      ok:          text.present? || calls.any?,
      text:        text,
      tool_calls:  calls,
      response_id: @session,
      error:       (Buddy::GPT::Client::EMPTY_TURN if text.empty? && calls.empty?),
      model:       model,
      usage:       usage(answer[:usage]),
    }
  end

  # One entry per model message in the round.
  def usage(messages)
    messages = Array(messages).select { |raw| raw.is_a?(Hash) }
    return nil if messages.empty?

    read   = messages.sum { |raw| raw[:cache_read_input_tokens].to_i }
    write  = messages.sum { |raw| raw[:cache_creation_input_tokens].to_i }
    input  = messages.sum { |raw| raw[:input_tokens].to_i } + read + write
    output = messages.sum { |raw| raw[:output_tokens].to_i }
    {
      input_tokens:        input,
      cached_input_tokens: read,
      output_tokens:       output,
      reasoning_tokens:    0,
      total_tokens:        input + output,
    }
  end

  def failed(error)
    { ok: false, text: "", tool_calls: [], error: error, model: model, usage: nil }
  end

  # Model time and cost only arrive with the reply, as running totals, so a
  # round that ended on calls logs none and the reply's round carries the turn.
  def log(started, answer, opened)
    FileUtils.mkdir_p(ROUNDS.dirname)
    row = {
      at:       started.iso8601,
      session:  @session,
      round:    @round,
      kind:     answer[:kind],
      warm:     opened&.dig(:warm),
      wall_ms:  ((Time.current - started) * 1000).round,
      mini_ms:  answer[:wall_ms],
      api_ms:   (answer[:duration_api_ms].to_i - @api_ms if answer[:duration_api_ms]),
      cost_usd: ((answer[:total_cost_usd].to_f - @cost).round(6) if answer[:total_cost_usd]),
      calls:    Array(answer[:calls]).map { |call| call.slice(:name, :meta) },
      usage:    answer[:usage],
      events:   answer[:events].to_a.map { |event| event.except(:uuid, :session_id) },
    }
    @api_ms = answer[:duration_api_ms].to_i if answer[:duration_api_ms]
    @cost   = answer[:total_cost_usd].to_f if answer[:total_cost_usd]
    File.open(ROUNDS, "a") { |file| file.puts(JSON.generate(row)) }
  end

  def post(**payload)
    uri  = URI("#{URL}/byte/turn")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 5
    http.read_timeout = TIMEOUT
    request = Net::HTTP::Post.new(
      uri,
      "Content-Type"  => "application/json",
      "X-Byte-Secret" => ENV.fetch("BYTE_LOCAL_SECRET", ""),
    )
    request.body = JSON.generate(payload)
    response = http.request(request)
    body = JSON.parse(response.body, symbolize_names: true)
    body.is_a?(Hash) ? body : { ok: false, error: response.body.to_s[0, 200] }
  rescue JSON::ParserError
    { ok: false, error: "#{response.code} #{response.body.to_s[0, 200]}" }
  end
end
