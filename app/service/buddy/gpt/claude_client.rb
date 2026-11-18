require "net/http"

module Buddy
  module GPT
    # Claude, through Claude Code on the Mac Mini, behind Client's contract: the
    # same `stream` arguments, the same events yielded and the same result
    # hash, so Turn runs its loop exactly as it does against OpenAI.
    #
    # It runs on the Mini's Claude login rather than an API key. Byte holds one
    # Claude Code session per turn (~/code/Byte/turn_sessions.rb) and serves the
    # tools to it as native ones. A call ends the round here like any model's
    # would; Turn runs it, and the next round's results are what let the
    # session's call return. The session remembers the conversation, so only
    # its first message carries the thread.
    #
    # Every tool goes over in full on the first round (see opens_everything?),
    # and Claude caches it, so there's no second stage to open them in.
    class ClaudeClient
      DEFAULT_MODEL = "claude-haiku-5-5".freeze
      EFFORTS = %w[low medium high xhigh max].freeze
      # Buddy's OpenAI setting, which Claude Code shares the name of.
      EFFORT  = Client::DEFAULT_REASONING_EFFORT

      # One round, Rails to the Mini and back, model time included. Byte gives
      # up on a reply after 120s on its side.
      TIMEOUT_SECONDS = 130

      # The plan's weekly allowance is everything Claude does on the Mini, the
      # builds and the Claude threads included, so Buddy steps aside just
      # before it runs out rather than taking the last of it.
      WEEKLY_LIMIT = 0.95
      # Set from the usage every reply reports; turns go to GPT until it expires
      # with the window it was set for.
      PAUSED = :buddy_claude_paused
      # A Mini that couldn't be reached is left alone for a little while, so
      # the turns behind it don't each wait out the same failure.
      DOWN     = :buddy_claude_down
      DOWN_FOR = 2.minutes

      # error_kind for a failure that was the Mini's rather than the model's.
      # Fallback hands those turns to GPT.
      MINI = :mini

      SEPARATOR = "\n\n---\n\n".freeze
      # Where Buddy::Personality's prompt stops being the same from turn to
      # turn. Everything before it is the session's system prompt, so the spare
      # the Mini keeps started matches the next turn; the rest leads the first
      # message.
      MOVING = ["## Right this second", "## Right now"].freeze

      # Claude Code names a served tool after its server, and the prompt names
      # tools bare.
      NAMING = <<~TXT.freeze
        ## Your tools

        Your tools are listed as mcp__buddy__NAME. Wherever these instructions name a tool, they
        mean that one: `remember` is mcp__buddy__remember. A line starting [app] is an instruction
        from the app, not something they said.
      TXT

      def self.available?
        !Rails.cache.exist?(PAUSED) && !Rails.cache.exist?(DOWN)
      end

      def self.mood_reading(session)
        new.mood_reading(session)
      end

      attr_reader :model, :mood_session
      # The mood reading to make once the model replies, so the Mini can start
      # it without waiting for Rails: Buddy::Sentiment.head_start.
      attr_accessor :mood

      # `rounds_log` is a path that gets one JSON line per round with its
      # timings, for the eval.
      def initialize(model: nil, effort: EFFORT, url: nil, rounds_log: nil)
        @model      = model.presence || ENV.fetch("BUDDY_CLAUDE_MODEL", DEFAULT_MODEL)
        @effort     = EFFORTS.include?(effort.to_s) ? effort.to_s : EFFORTS.first
        @url        = url
        @rounds_log = rounds_log
        reset
      end

      def opens_everything?
        true
      end

      # Turn starts over with a fresh input when an attempt went nowhere, and an
      # input that isn't this one carried on gets a new session.
      def stream(instructions:, input:, tools: [], deadline: nil)
        started = Time.current
        finish unless input.first(@sent.length) == @sent
        answer = round(instructions, tools, input.drop(@sent.length), deadline)
        @sent  = input.dup
        watch_allowance(answer[:events])
        return mini_failure(answer[:error]) unless answer[:ok]

        log(started, answer)
        result = parse(answer)
        @mood_session = @session if @mood && answer[:kind].to_s == "reply"
        if block_given?
          yield({ type: :text_delta, text: result[:text] }) if result[:text].present?
          result[:tool_calls].each { |call| yield({ type: :tool_call, **call }) }
        end
        result
      rescue StandardError => e
        mini_failure("#{e.class}: #{e.message}")
      end

      # The mood reading the Mini started when a turn's session replied (see
      # `mood=`), as a result hash like any other, waiting for it if it isn't
      # done yet. nil when there's none to collect, which isn't the Mini being
      # down: the caller just reads the mood itself.
      def mood_reading(session)
        answer = post(nil, action: :mood, id: session)
        return nil unless answer[:ok]

        watch_allowance(answer[:events])
        parse(answer)
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::ClaudeClient] mood reading: #{e.class}: #{e.message}")
        nil
      end

      # Ends the turn's session on the Mini. Safe to call twice.
      def finish
        post(nil, action: :close, id: @session) if @session
      rescue StandardError
        nil
      ensure
        reset
      end

      private

      def reset
        @session = nil
        @sent    = []
        @waiting = false
        # Claude reports model time and cost as running totals for the session.
        @api_ms  = 0
        @cost    = 0.0
      end

      def round(instructions, tools, fresh, deadline)
        return post(deadline, action: :answer, id: @session, results: results(fresh)) if @waiting
        if @session
          return post(deadline, action: :say, id: @session, message: message(notes(fresh)))
        end

        steady, moving = split(instructions)
        open!(steady, tools, deadline)
        post(deadline, action: :say, id: @session, message: opening(moving, fresh))
      end

      def split(instructions)
        parts = instructions.split(SEPARATOR)
        at    = parts.index { |part| part.start_with?(*MOVING) } || parts.length
        [parts[0...at].join(SEPARATOR), parts[at..].join(SEPARATOR)]
      end

      def open!(steady, tools, deadline)
        opened = post(
          deadline,
          action: :open,
          system: [steady, (NAMING if tools.any?)].compact.join(SEPARATOR),
          model:  model,
          effort: @effort,
          tools:  tools,
          mood:   @mood,
        )
        raise opened[:error].to_s unless opened[:ok]

        @session = opened[:id]
      end

      # The thread so far, then what they just said and anything the app added
      # after it.
      def opening(moving, items)
        said    = items.rindex { |item| item[:type].nil? && item[:role]&.to_sym == :user }
        said  ||= items.length
        earlier = items[0...said].select { |item| item[:type].nil? }
        blocks  = []
        blocks << text(moving) if moving.present?
        if earlier.any?
          blocks << text("Earlier in this conversation:")
          earlier.each { |item| blocks.concat(parts(item, by: speaker(item))) }
        end
        blocks.concat(parts(items[said])) if items[said]
        blocks.concat(notes(items.drop(said + 1)))
        message(blocks)
      end

      # The outputs of the calls the last round handed back. What the app adds
      # alongside rides on the last of them, as nothing else reaches the model
      # while its calls are out: a note, or a picture a tool put back in front
      # of it.
      def results(items)
        outputs = []
        items.each { |item|
          if item[:type]&.to_sym == :function_call_output
            outputs << { id: item[:call_id], output: item[:output].to_s, images: [] }
          elsif item[:type].nil? && outputs.any?
            by = ("[app] " if item[:role]&.to_sym == :developer)
            parts(item, by: by).each { |part|
              next outputs.last[:images] << part.dig(:source, :url) if part[:type] == :image

              outputs.last[:output] += "\n\n#{part[:text]}"
            }
          end
        }
        outputs
      end

      # What the app adds between rounds when no call is out. The model's own
      # draft is already in the session.
      def notes(items)
        added = items.select { |item| item[:type].nil? && item[:role]&.to_sym != :assistant }
        added.flat_map { |item| parts(item, by: ("[app] " if item[:role].to_sym == :developer)) }
      end

      def speaker(item)
        { user: "Them: ", assistant: "You: ", developer: "[app] " }[item[:role]&.to_sym]
      end

      # Responses-API content as Messages-API blocks.
      def parts(item, by: nil)
        content = item[:content]
        content = [{ type: :input_text, text: content.to_s }] unless content.is_a?(Array)
        blocks  = content.filter_map { |part|
          part = part.to_h.symbolize_keys
          case part[:type]&.to_sym
          when :input_image
            { type: :image, source: { type: :url, url: part[:image_url].to_s } }
          else text(part[:text].to_s) if part[:text].present?
          end
        }
        first = blocks.index { |block| block[:type] == :text }
        if first
          blocks[first] = text("#{by}#{blocks[first][:text]}")
        else
          blocks.unshift(text(by.to_s.strip))
        end
        blocks.reject { |block| block[:type] == :text && block[:text].blank? }
      end

      def text(body)
        { type: :text, text: body }
      end

      # Plain text unless there's a picture in it.
      def message(blocks)
        return blocks.pluck(:text).join("\n\n") if blocks.all? { |block| block[:type] == :text }

        blocks
      end

      def parse(answer)
        @waiting = answer[:kind].to_s == "calls"
        calls = Array(answer[:calls]).map { |call|
          arguments = call[:arguments].is_a?(Hash) ? call[:arguments].deep_stringify_keys : {}
          { name: call[:name].to_sym, call_id: call[:id].to_s, arguments: arguments }
        }
        text  = answer[:text].to_s.strip
        empty = text.empty? && calls.empty?
        {
          ok:          !empty,
          text:        text,
          tool_calls:  calls,
          response_id: @session,
          error:       (Client::EMPTY_TURN if empty),
          error_kind:  nil,
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

      # Each reply carries the plan's rate-limit windows. One that's refusing,
      # or the week past WEEKLY_LIMIT, pauses Claude until that window resets.
      def watch_allowance(events)
        Array(events).each { |event|
          info = event[:rate_limit_info] if event[:type].to_s == "rate_limit_event"
          next if info.nil?

          windows = (info[:unifiedWindows] || {}).to_h
          windows = { info[:rateLimitType] => info } if windows.empty?
          windows.each { |name, window|
            used = window[:utilization].to_f
            full = name.to_s == "seven_day" && used >= WEEKLY_LIMIT
            over = full || window[:status].to_s != "allowed"
            next unless over && window[:resetsAt].present?

            Rails.logger.warn("[Buddy::GPT::ClaudeClient] #{name} at #{used}: GPT until it resets")
            Rails.cache.write(PAUSED, name.to_s, expires_at: Time.zone.at(window[:resetsAt].to_i))
          }
        }
      end

      def mini_failure(error)
        @mood_session = nil
        Rails.logger.warn("[Buddy::GPT::ClaudeClient] #{error.to_s.truncate(200)}")
        Rails.cache.write(DOWN, error.to_s.truncate(200), expires_in: DOWN_FOR)
        finish
        {
          ok:          false,
          text:        "",
          tool_calls:  [],
          response_id: nil,
          error:       error.to_s,
          error_kind:  MINI,
          model:       model,
          usage:       nil,
        }
      end

      # Model time and cost only arrive with a reply, as session totals, so a
      # round that ended on calls logs none of either.
      def log(started, answer)
        return if @rounds_log.nil?

        row = {
          at:       started.iso8601,
          session:  @session,
          kind:     answer[:kind],
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
        FileUtils.mkdir_p(File.dirname(@rounds_log))
        File.open(@rounds_log, "a") { |file| file.puts(JSON.generate(row)) }
      end

      def post(deadline, **payload)
        uri  = URI("#{@url || ByteLocal.base_url(:mini)}/byte/turn")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = uri.scheme == "https"
        http.open_timeout = 5
        left = deadline ? deadline - Time.current : TIMEOUT_SECONDS
        http.read_timeout = left.clamp(5, TIMEOUT_SECONDS)
        request = Net::HTTP::Post.new(
          uri,
          "Content-Type"  => "application/json",
          "X-Byte-Secret" => ByteLocal.secret,
        )
        request.body = JSON.generate(payload)
        response = http.request(request)
        body = JSON.parse(response.body, symbolize_names: true)
        body.is_a?(Hash) ? body : { ok: false, error: "#{response.code} from the Mini" }
      rescue JSON::ParserError
        { ok: false, error: "#{response.code} from the Mini" }
      end
    end
  end
end
