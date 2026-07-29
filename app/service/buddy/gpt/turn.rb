module Buddy
  module GPT
    # One Buddy turn, start to finish, entirely inside Rails.
    #
    # Replaces the old Rails -> Mac -> `claude -p` -> Rails round trip. The Mac
    # is still the host for Byte's claude and terminal modes; Buddy no longer
    # touches it, which is why Buddy now works while the Mac is asleep.
    #
    # Responsibilities, in order:
    #   1. Mint the streaming reply bubble.
    #   2. Stream from the model, pushing throttled body updates.
    #   3. Fire side-effect tool calls the instant they arrive.
    #   4. Round-trip read tools (get_context) and continue the same reply.
    #   5. Hand proposal tool calls to Buddy::ProposalBuilder.
    #   6. Finalize the bubble and settle the pet's expression.
    #
    # The `client:` seam is what keeps this testable: specs inject a fake client
    # that yields recorded events, so none of the above needs the network.
    class Turn
      # A read tool can ask the model to continue with what it learned. Capped
      # so a model that keeps re-reading can't spin: 1 initial pass plus at most
      # two follow-ups is plenty for "greet me" -> read -> brief.
      MAX_ROUND_TRIPS = 3

      # Matches the cadence the Mac streamer used, which the client's typing
      # animation is already tuned against.
      UPDATE_THROTTLE_MS = 150

      PLACEHOLDER = "…".freeze

      FALLBACK_BODY = "Hmm, I couldn't quite line that one up - can you give me a little more to go on?".freeze

      # Defensive only. The model emits structured tool calls now, but if prompt
      # residue makes it write a `[[marker]]` we strip it rather than show
      # brackets to the person — and log it, because a marker in the output means
      # some prompt section still teaches the retired protocol.
      STRAY_MARKER_RX = /\[\[\s*[a-z_]+\s*:[^\]]*\]\]/i

      def self.run!(message, client: nil)
        new(message, client: client).run!
      end

      def initialize(message, client: nil)
        @inbound      = message
        @conversation = message.byte_conversation
        @user         = @conversation.user
        @client       = client || Client.new
        @context_tool = ContextTool.new(@user, @conversation)
        @last_push_ms = 0
      end

      def run!
        @reply = create_reply
        outcome = converse
        outcome[:ok] ? finalize_success(outcome) : finalize_failure(outcome[:error])
        outcome[:ok]
      rescue StandardError => e
        Buddy::Errors.report(
          section:   "gpt.turn",
          exception: e,
          user:      @user,
          extra:     { conversation_id: @conversation.id, message_id: @inbound.id },
        )
        finalize_failure("#{e.class}: #{e.message}") if @reply
        false
      end

      private

      # ---- the model loop ----------------------------------------------------

      def converse
        input     = History.build(@conversation, upto: @inbound)
        text      = String.new(encoding: "UTF-8")
        proposals = []
        rounds    = 0

        loop do
          rounds += 1
          # Prose from a later round is a new paragraph, not a continuation of
          # the placeholder that preceded the lookup. Without this you get
          # "One sec.Nothing left on your list." in one run-on line.
          text << "\n\n" if rounds > 1 && !text.empty? && !text.end_with?("\n")

          result = stream_once(input, text)
          # Record usage BEFORE the ok check: a failed or truncated response
          # still consumed tokens and still bills.
          record_usage(result)
          return { ok: false, error: result[:error] } unless result[:ok]

          calls = result[:tool_calls]
          proposals.concat(calls.select { |c| proposal?(c[:name]) })

          reads = calls.select { |c| c[:name].to_sym == ContextTool::NAME }
          break if reads.empty? || rounds >= MAX_ROUND_TRIPS

          # Carry this round's prose forward. Without it the model doesn't know
          # it already said "one sec, let me check" and says it again on top of
          # the answer, in the same bubble.
          round_text = result[:text].to_s.strip
          input += [{ role: :assistant, content: round_text }] if round_text.present?
          # A function_call_output is only accepted alongside the function_call
          # it answers, so both items go back on the input.
          input += reads.flat_map { |call| round_trip_items(call) }
        end

        { ok: true, text: text, proposals: proposals }
      end

      def stream_once(input, text)
        @client.stream(instructions: instructions, input: input, tools: tools) { |event|
          case event[:type]
          when :text_delta
            text << event[:text]
            push_preview(text)
          when :tool_call
            # Side effects fire mid-stream so the face moves WITH the words
            # instead of a beat behind, which the old marker path couldn't do
            # (Rails only saw markers once the whole body had arrived).
            Buddy::SideEffects.call(@conversation, event[:name], event[:arguments]) if
              Buddy::SideEffects.handles?(event[:name])
          end
        }
      end

      def round_trip_items(call)
        [
          {
            type:      :function_call,
            call_id:   call[:call_id],
            name:      call[:name].to_s,
            arguments: JSON.generate(call[:arguments]),
          },
          {
            type:    :function_call_output,
            call_id: call[:call_id],
            output:  @context_tool.call(call[:arguments]),
          },
        ]
      end

      def proposal?(name)
        Buddy::Tools.known?(name)
      end

      # ---- cost accounting ---------------------------------------------------

      # One row per API call, attached to the reply so per-message cost is a sum
      # over them. Wrapped: losing a usage row is an accounting gap, never a
      # reason to fail a turn the person is waiting on.
      def record_usage(result)
        BuddyUsage.record!(
          result,
          user:         @user,
          kind:         :turn,
          conversation: @conversation,
          message:      @reply,
        )
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] usage record failed: #{e.class}: #{e.message}")
      end

      # Denormalize the per-message total onto the reply so the client can show a
      # cost without joining, and so the number survives even if usage rows are
      # pruned later.
      def stamp_usage_rollup
        rollup = BuddyUsage.rollup_for_message(@reply)
        return if rollup.nil?

        @reply.update!(metadata: (@reply.metadata || {}).merge("usage" => rollup))
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] usage rollup failed: #{e.class}: #{e.message}")
      end

      # ---- prompt + tools ----------------------------------------------------

      def instructions
        @instructions ||= Buddy::Personality.for(
          @user,
          conversation: @conversation,
          at_glance:    at_glance,
          recap:        recap,
        )
      end

      def tools
        @tools ||= [
          ContextTool.schema,
          *Buddy::SideEffects.function_schemas(theme: @conversation.buddy_theme),
          *Buddy::Tools.function_schemas,
        ]
      end

      # The handful of always-needed values, inlined so a chat-only turn never
      # has to spend a round trip on get_context just to know its own face.
      #
      # open_questions_from_partner is here rather than behind get_context because
      # it changes how an otherwise meaningless message should be read: a bare
      # "tacos" is an answer to relay back if a question is open, and small talk
      # if none is. Buddy can't know to go looking for something it has no hint
      # exists, so the count rides along every turn.
      def at_glance
        {
          user:                        @user.first_name,
          pet_expression:              @conversation.buddy_expression.presence || "neutral",
          open_questions_from_partner: open_relay_count,
        }
      end

      def open_relay_count
        BuddyRelay.open_questions_for(@user).count
      rescue StandardError
        0
      end

      def recap
        @conversation.metadata.is_a?(Hash) ? @conversation.metadata["buddy_recap"] : nil
      end

      # ---- message lifecycle -------------------------------------------------

      def create_reply
        msg = @conversation.byte_messages.create!(
          user:      @user,
          direction: :inbound,
          state:     :streaming,
          body:      PLACEHOLDER,
          metadata:  { "kind" => "buddy", "in_reply_to" => @inbound.id },
        )
        broadcast(msg)
        msg
      end

      def push_preview(text)
        now_ms = (Time.current.to_f * 1000).to_i
        return if now_ms - @last_push_ms < UPDATE_THROTTLE_MS

        preview = text.strip
        # Skip empty pushes. When the model leads with a tool call, the stripped
        # preview is still empty, and writing body="" would replace the "…"
        # placeholder with a blank bubble.
        return if preview.empty?

        @last_push_ms = now_ms
        # update_columns on purpose: a streaming reply writes this many times per
        # second, and going through save would fire bump_conversation_activity
        # (an after_commit touch on the conversation) on every keystroke-sized
        # delta. The finalize update is a real save.
        @reply.update_columns(body: preview, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        broadcast(@reply)
      end

      def finalize_success(outcome)
        body = display_body(outcome[:text])
        @reply.update!(state: :delivered, body: body, delivered_at: Time.current)

        result = build_proposals(outcome[:proposals])

        # Never leave a blank bubble. This is the "every tool call got discarded
        # and there was no prose" case — give honest, warm feedback instead of
        # an empty message with no explanation.
        if @reply.body.to_s.strip.empty? && result[:action].nil? && !result[:auto_ran]
          @reply.update!(body: FALLBACK_BODY)
        end

        stamp_usage_rollup
        settle_expression
        broadcast(@reply.reload)
        ByteNotifier.notify(@user, @reply)
      end

      def finalize_failure(error)
        Rails.logger.warn("[Buddy::GPT::Turn] turn failed: #{error}")
        @reply.update!(
          state:    :failed,
          body:     "buddy error: #{error.to_s.truncate(600)}",
          metadata: (@reply.metadata || {}).merge("kind" => "buddy"),
        )
        # A failed turn still cost something; stamp what it was.
        stamp_usage_rollup
        settle_expression
        broadcast(@reply.reload)
      end

      def build_proposals(proposals)
        return { action: nil, auto_ran: false } if proposals.empty?

        markers = proposals.map { |call|
          tool = Buddy::Tools[call[:name]]
          { tool_name: call[:name], payload: Buddy::Tools.normalize_function_arguments(tool, call[:arguments]) }
        }
        Buddy::ProposalBuilder.create(user: @user, byte_message: @reply, markers: markers)
      end

      # Resolve the transient `thinking` overlay set at turn start. If Buddy
      # called set_mood this turn, SideEffects already persisted and broadcast
      # it; settle just re-asserts the stored mood so the overlay drops without
      # changing the face.
      def settle_expression
        Buddy::ExpressionState.settle!(@conversation)
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] settle failed: #{e.class}: #{e.message}")
      end

      def display_body(text)
        raw = text.to_s
        return raw.strip unless raw.match?(STRAY_MARKER_RX)

        Rails.logger.warn("[Buddy::GPT::Turn] stray marker in output: #{raw[STRAY_MARKER_RX]}")
        raw.gsub(STRAY_MARKER_RX, "").gsub(/\n{3,}/, "\n\n").strip
      end

      def broadcast(message)
        MonitorChannel.broadcast_to(@user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.as_wire },
        })
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] broadcast failed: #{e.class}: #{e.message}")
      end
    end
  end
end
