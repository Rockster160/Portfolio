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
      # Every round of tool calls needs a follow-up round for the model to answer
      # in, so the cap has to allow the deepest legitimate chain: look something
      # up, act on what it found, then speak. That's three calls plus the closing
      # one. Beyond that a model is spinning, not working.
      MAX_ROUNDS = 4

      # What we hand back as a tool's output. The model has to know whether the
      # thing it called has HAPPENED or is merely waiting on a tap, because the
      # tense it writes in depends on it (see the three-kinds-of-action section of
      # the prompt). Levels come straight from the registry, so this can't drift
      # from how ProposalBuilder actually treats them.
      #
      # Level 1 and 2 do run for real, moments later in build_proposals — the same
      # ordering marker-era Buddy had, where prose was written before Rails
      # executed anything.
      def self.ack_for(tool)
        case tool[:level]
        when 1
          { status: "done", note: "Ran immediately. Speak about it as done." }
        when 2
          {
            status: "done_undoable",
            note:   "Ran immediately and shows as a pre-checked row the person can uncheck to undo. " \
                    "Speak about it as done.",
          }
        else
          {
            status: "proposed",
            note:   "A checkbox row is now waiting for the person to tap. It has NOT happened yet - " \
                    "do not say it's done, logged, or added.",
          }
        end
      end

      # The bubble minted at turn start, which the client renders as a live pulsing
      # placeholder — that IS the typing indicator. Its body is replaced once, with
      # the finished reply. Buddy answers in 1-3 sentences in about a second, so
      # there's nothing worth animating in between.
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

      # Runs the model until it stops calling tools, accumulating its prose.
      #
      # The load-bearing detail: emitting a function call ENDS the model's turn.
      # It writes no text alongside one, and expects the tool's output back before
      # it says anything. So every call has to be answered — not just the read
      # tools — or the person gets an empty bubble on any turn that logs, sets a
      # mood, or proposes something. That was the whole failure mode of the first
      # cut of this: 13 of 16 eval scenarios came back with no prose at all.
      #
      # Marker-era Buddy didn't have this problem because the marker was embedded
      # in the text, so words and action arrived together. Structured calls split
      # them across turns, and this loop is what stitches them back into one reply.
      def converse
        input     = History.build(@conversation, upto: @inbound)
        spoken    = []
        proposals = []
        rounds    = 0

        loop do
          rounds += 1
          result = run_round(input)
          # Record usage BEFORE the ok check: a failed or truncated response still
          # consumed tokens and still bills.
          record_usage(result)
          return { ok: false, error: result[:error] } unless result[:ok]

          calls = result[:tool_calls]
          # Prose arrives one of two ways: as ordinary output text (when the model
          # called nothing, or on a follow-up round), or riding on a tool call's
          # reply field.
          round_text = result[:text].to_s.strip
          inline     = Buddy::Tools.spoken_reply(calls)
          spoken << round_text if round_text.present?
          spoken << inline if inline.present?

          break if calls.empty?

          # Proposals are collected and built ONCE after the loop, so a turn can
          # never end up with two checklists attached to one reply.
          proposals.concat(calls.select { |c| proposal?(c[:name]) })

          # Only a READ forces another round: the model can't answer until it sees
          # what came back. Actions need nothing returned, so if the model already
          # spoke inline we're done — that's the whole point of the reply field,
          # and it halves the cost and latency of a logging turn.
          reads = calls.select { |c| c[:name].to_sym == ContextTool::NAME }
          break if reads.empty? && spoken.any?
          break if rounds >= MAX_ROUNDS

          # Carry forward whatever was spoken this round, from EITHER source. Only
          # feeding back output_text left the model blind to its own inline reply,
          # so it opened the next round by saying the same thing again and the
          # person got "Oof, yeah. I'll pull it out." twice in one bubble.
          said = [round_text, inline].compact_blank.join("\n\n")
          input += [{ role: :assistant, content: said }] if said.present?
          input += calls.flat_map { |call| call_items(call) }
        end

        { ok: true, text: spoken.join("\n\n"), proposals: proposals }
      end

      # No incremental rendering: Buddy replies are 1-3 sentences and land in
      # about a second, so the placeholder bubble acts as the typing indicator and
      # the finished message is written once. Deltas are still consumed (the
      # client's contract is a complete body), and side effects still fire the
      # moment they arrive so the face moves before the words appear.
      def run_round(input)
        @client.stream(instructions: instructions, input: input, tools: tools) { |event|
          next unless event[:type] == :tool_call
          next unless Buddy::SideEffects.handles?(event[:name])

          Buddy::SideEffects.call(@conversation, event[:name], event[:arguments])
        }
      end

      # A function_call_output is only accepted alongside the function_call it
      # answers, so both items go back on the input together.
      def call_items(call)
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
            output:  tool_output(call),
          },
        ]
      end

      def tool_output(call)
        name = call[:name].to_sym
        return @context_tool.call(call[:arguments]) if name == ContextTool::NAME
        # Silent tools already ran as their call arrived (see run_round).
        return JSON.generate({ ok: true }) if Buddy::SideEffects.handles?(name)

        tool = Buddy::Tools[name]
        return JSON.generate({ ok: false, error: "no tool named #{name}" }) if tool.nil?

        JSON.generate(self.class.ack_for(tool))
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
