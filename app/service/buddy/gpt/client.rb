module Buddy
  module GPT
    # Transport for one Buddy turn against the OpenAI Responses API.
    #
    # This is deliberately the ONLY object in the Buddy pipeline that knows
    # about HTTP, SSE framing, or OpenAI's event vocabulary. Everything above
    # it works in terms of the two semantic events yielded here, which is what
    # lets Buddy::GPT::Turn be tested against a fake client with no network.
    #
    # Yields, in stream order:
    #   { type: :text_delta, text: "..." }
    #   { type: :tool_call, name: :complete_chore, call_id: "...", arguments: {} }
    #
    # Returns:
    #   { ok:, text:, tool_calls: [], response_id:, error:, model:, usage: }
    class Client
      # Responses-API function tools are FLAT (type/name/description/parameters
      # at the top level). Chat Completions nests them under `function`; that
      # shape 400s here. See Buddy::Tools.function_schemas.
      ENDPOINT = "/responses".freeze

      # SSE event names we act on. Everything else (reasoning summaries, item
      # lifecycle bookkeeping, output_text.done) is ignored on purpose: the
      # deltas already carried the text, and output_item.done already carried
      # complete tool-call arguments.
      TEXT_DELTA = "response.output_text.delta".freeze
      ITEM_DONE  = "response.output_item.done".freeze
      COMPLETED  = "response.completed".freeze
      FAILED     = "response.failed".freeze
      INCOMPLETE = "response.incomplete".freeze
      ERROR      = "error".freeze

      DEFAULT_MODEL = "gpt-5.4-mini".freeze

      # Sending no `reasoning` parameter is NOT the same as asking for a little
      # reasoning: 53 consecutive prod calls came back with literally zero
      # reasoning tokens, so Buddy was answering entirely off the cuff.
      #
      # `low` is measured, not assumed. Against "just got back from a walk with
      # the puppy" - the phrasing that had been dropping its complete_chore call
      # roughly half the time - the three settings ran:
      #
      #   no parameter  2/4 called, ~3s
      #   medium        1/4 called, ~6s      (and 2/3 on cases that were 3/3)
      #   low           7/7 called, ~3s
      #
      # More reasoning made tool-calling WORSE and doubled latency, which is
      # counterintuitive enough to be worth writing down: a bigger budget seems
      # to get spent deliberating toward a conversational answer rather than
      # acting. Raise this only with numbers in hand.
      DEFAULT_REASONING_EFFORT = ENV.fetch("BUDDY_GPT_REASONING", "low").freeze

      # Faraday's timeout is per-READ, not wall clock: as long as bytes keep
      # arriving it never fires. This is the backstop for a stream that goes
      # completely silent. For a stream that merely trickles, see the deadline.
      TIMEOUT_SECONDS = 120

      # Raised when a turn blows its wall-clock budget. Carries whatever had
      # already streamed, so a slow-but-useful reply isn't thrown away.
      DeadlineExceeded = Class.new(StandardError)

      attr_reader :model

      # `reasoning_effort: nil` omits the parameter entirely, which is what a
      # mechanical call (compaction) wants - it has no judgement to exercise.
      def initialize(model: nil, timeout: TIMEOUT_SECONDS, reasoning_effort: DEFAULT_REASONING_EFFORT)
        @model            = model.presence || ENV.fetch("BUDDY_GPT_MODEL", DEFAULT_MODEL)
        @timeout          = timeout
        @reasoning_effort = reasoning_effort.presence
      end

      # `deadline` is an absolute Time. Checked on every SSE event, which is
      # exactly the case Faraday's read timeout can't see: a stream that keeps
      # dribbling tokens resets the read clock forever. One prod turn ran 3m45s
      # this way and blocked every message behind it on the conversation lock.
      def stream(instructions:, input:, tools: [], deadline: nil, &block)
        text        = String.new(encoding: "UTF-8")
        tool_calls  = []
        response_id = nil
        usage       = nil
        # Locals, not ivars: the handler closes over them, and a reused client
        # instance must not carry an error or a token count from a previous turn
        # into this one.
        stream_error = nil
        # Which output part the last delta belonged to. One response can carry
        # SEVERAL message items, and their deltas arrive interleaved into this
        # one buffer with nothing marking the seam.
        last_part = nil

        handler = proc { |event|
          case event["type"]
          when TEXT_DELTA
            delta = event["delta"].to_s
            unless delta.empty?
              # Prod message 1106 came back as "...keep an eye on that.Yep, I'm
              # watching..." - two separate replies fused mid-sentence because
              # every delta was appended blind. Reinstate the boundary the API
              # gave us rather than letting the parts run together.
              part = [event["item_id"], event["content_index"]]
              text << "\n\n" if last_part && part != last_part && !text.empty?
              last_part = part

              text << delta
              block&.call({ type: :text_delta, text: delta })
            end
          when ITEM_DONE
            call = extract_tool_call(event["item"])
            if call
              tool_calls << call
              block&.call(call.merge(type: :tool_call))
            end
          when COMPLETED
            response_id = event.dig("response", "id")
            # Usage rides ONLY on the terminal event, and it's authoritative —
            # never try to derive token counts by counting deltas.
            usage = extract_usage(event)
          when FAILED, INCOMPLETE
            response_id  = event.dig("response", "id")
            # A failed or truncated response still consumed tokens and still
            # bills, so capture usage here too rather than only on success.
            usage        = extract_usage(event)
            stream_error = stream_error_message(event)
          when ERROR
            stream_error = event["message"].presence || "stream error"
          end

          # Checked AFTER handling, so the event that trips the budget is still
          # kept. Losing a chunk to be a few milliseconds more punctual is a bad
          # trade when the whole point is salvaging a slow reply.
          raise DeadlineExceeded if deadline && Time.current > deadline
        }

        client.responses.create(parameters: request_parameters(
          instructions: instructions, input: input, tools: tools, handler: handler,
        ))

        result(text: text, tool_calls: tool_calls, response_id: response_id, error: stream_error, usage: usage)
      rescue DeadlineExceeded
        # Keep what we got. Only complete items ever reach us (tool calls arrive
        # on `output_item.done`), so a truncated stream can't yield half-parsed
        # arguments — partial prose is the worst case, and that beats an error
        # bubble. Usage is lost because the terminal event never arrived.
        Rails.logger.warn("[Buddy::GPT::Client] stream exceeded its deadline; keeping #{text.length} chars")
        {
          ok: text.strip.present? || tool_calls.any?, text: text, tool_calls: tool_calls,
          response_id: response_id, error: ("timed out" if text.strip.empty? && tool_calls.empty?),
          model: model, usage: usage,
        }
      rescue StandardError => e
        # Faraday raises on non-200 (the gem installs :raise_error), so an API
        # rejection lands here rather than arriving as an ERROR event. A rejected
        # request bills nothing, so usage stays nil.
        {
          ok:          false,
          text:        text.to_s,
          tool_calls:  tool_calls,
          response_id: response_id,
          error:       describe(e),
          model:       model,
          usage:       usage,
        }
      end

      private

      def result(text:, tool_calls:, response_id:, error:, usage:)
        # A turn that produced neither prose nor a tool call is a failure even
        # with a 200 — there is nothing to show the person and nothing to run.
        empty = text.strip.empty? && tool_calls.empty?
        {
          ok:          error.nil? && !empty,
          text:        text,
          tool_calls:  tool_calls,
          response_id: response_id,
          error:       error || (empty ? "model returned no text and no tool calls" : nil),
          model:       model,
          usage:       usage,
        }
      end

      # Flatten the API's nested usage payload into the shape Pricing and
      # BuddyUsage both work in. Note what the field names hide: `input_tokens`
      # INCLUDES `cached_tokens`, and `output_tokens` INCLUDES `reasoning_tokens`.
      # Both nested detail objects can be absent on some responses.
      def extract_usage(event)
        raw = event.dig("response", "usage")
        return nil unless raw.is_a?(Hash)

        {
          input_tokens:        raw["input_tokens"].to_i,
          cached_input_tokens: raw.dig("input_tokens_details", "cached_tokens").to_i,
          output_tokens:       raw["output_tokens"].to_i,
          reasoning_tokens:    raw.dig("output_tokens_details", "reasoning_tokens").to_i,
          total_tokens:        raw["total_tokens"].to_i,
        }
      end

      def request_parameters(instructions:, input:, tools:, handler:)
        params = {
          model:        model,
          instructions: instructions,
          input:        input,
          stream:       handler,
          # We rebuild history from ByteMessage rows every turn and never use
          # previous_response_id, so there is nothing to gain from server-side
          # retention.
          store:        false,
        }
        params[:tools]     = tools if tools.present?
        params[:reasoning] = { effort: @reasoning_effort } if @reasoning_effort
        params
      end

      # `response.output_item.done` is self-contained for function calls: it
      # carries name, call_id, and the complete arguments string. Using it
      # avoids correlating `output_item.added` against
      # `function_call_arguments.done` by item_id, and it fires as soon as the
      # individual call completes rather than at end of turn.
      def extract_tool_call(item)
        return nil unless item.is_a?(Hash) && item["type"] == "function_call"

        name = item["name"].to_s
        return nil if name.empty?

        args = parse_arguments(item["arguments"])
        return nil if args.nil?

        { name: name.to_sym, call_id: item["call_id"].to_s, arguments: args }
      end

      # Malformed arguments are dropped rather than raised: one bad tool call
      # must not cost the person the rest of a good reply.
      def parse_arguments(raw)
        return {} if raw.nil? || raw.to_s.strip.empty?

        parsed = JSON.parse(raw.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        Rails.logger.warn("[Buddy::GPT::Client] unparseable tool arguments: #{raw.to_s[0, 200]}")
        nil
      end

      def stream_error_message(event)
        event.dig("response", "error", "message").presence ||
          event.dig("response", "incomplete_details", "reason").presence ||
          "stream ended #{event["type"]}"
      end

      def describe(exception)
        body = exception.respond_to?(:response) ? exception.response : nil
        detail = body.is_a?(Hash) ? body.dig(:body, "error", "message") : nil
        detail.presence || "#{exception.class}: #{exception.message}"
      end

      def client
        # log_errors only in development: it dumps the raw error body, which is
        # useful while iterating, noise in prod, and clutters spec output for
        # the tests that deliberately provoke a 400.
        @client ||= ::OpenAI::Client.new(request_timeout: @timeout, log_errors: Rails.env.development?)
      end
    end
  end
end
