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

      # Wall-clock budget for the WHOLE turn, shared across rounds so a
      # round-trip can't multiply it. A normal turn is 1-3s; this only bites on
      # a pathological stream. It has to stay under TurnDispatcher's lock wait,
      # or a slow turn would still block the next message on the same
      # conversation for longer than it took to give up.
      TURN_BUDGET_SECONDS = 90

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
        @deadline = Time.current + TURN_BUDGET_SECONDS

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
          # The model often writes the SAME sentence as output text AND into the
          # reply field of its call. Appending both printed the line twice in one
          # bubble ("You got it, checking that off." / "You got it, checking that
          # off."), so anything we've already said is dropped rather than repeated.
          add_spoken(spoken, round_text)
          add_spoken(spoken, inline)

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
          # Out of budget: another round would just abort on arrival. Take what
          # we have rather than burning a call to be told the same thing.
          break if Time.current > @deadline

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
        @client.stream(instructions: instructions, input: input, tools: tools, deadline: @deadline) { |event|
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

      # Collect a line unless we've effectively said it already. Compared on a
      # normalized form so punctuation or capitalization drift doesn't sneak a
      # near-duplicate through, and containment counts either way — a round-two
      # restatement is usually a superset of the round-one line.
      def add_spoken(spoken, line)
        text = line.to_s.strip
        return if text.empty?

        norm = normalize_spoken(text)
        return if spoken.any? { |prior|
          p_norm = normalize_spoken(prior)
          p_norm == norm || p_norm.include?(norm) || norm.include?(p_norm)
        }

        spoken << text
      end

      def normalize_spoken(text)
        text.to_s.downcase.gsub(/[^a-z0-9 ]/, "").squish
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

        proposals = outcome[:proposals]
        result    = build_proposals(proposals)
        nothing   = result[:action].nil? && !result[:auto_ran]

        # A tool call that gets discarded (a chore name that resolves to nothing,
        # an arg that fails validation) is silent by design — ProposalBuilder just
        # drops it. But the model has ALREADY written its line by then, and that
        # line usually claims the thing happened. Left alone, the person reads
        # "You got it, checking that off." under a reply that recorded nothing and
        # shows no checkbox, and they have no way to tell.
        #
        # So when we had proposals and NONE survived, the prose can't stand.
        # Replace it rather than appending: "checking that off, but actually I
        # couldn't" is worse than a clean honest ask.
        if proposals.any? && nothing
          Rails.logger.warn(
            "[Buddy::GPT::Turn] all #{proposals.length} proposal(s) discarded for " \
            "message=#{@reply.id} user=#{@user.id}: #{proposals.map { |p| p[:name] }.inspect}",
          )
          @reply.update!(body: FALLBACK_BODY)
        elsif @reply.body.to_s.strip.empty? && nothing
          # Nothing proposed and nothing said — never leave a blank bubble.
          @reply.update!(body: FALLBACK_BODY)
        else
          retract_false_claim!(result)
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

      # Phrases that assert the thing ALREADY HAPPENED. Kept deliberately narrow
      # and unambiguous: a false negative here is a missed catch, but a false
      # positive rewrites a perfectly good reply, which is worse. Anything hedged
      # ("want me to", "I can") is not a claim and isn't listed.
      COMPLETION_CLAIM_RX = /
        \b(?:check(?:ing|ed)?\s+(?:that|it|those|them|this)\s+off)\b
        | \b(?:checked\s+off|marked\s+(?:it|that|those)?\s*(?:off|done)|crossed\s+off)\b
        | \b(?:logged|recorded|credited|crediting)\b
        | \b(?:timer(?:'|’)?s\s+set|reminder(?:'|’)?s\s+set|set\s+(?:a|the)\s+timer)\b
        | \b(?:added\s+(?:it|that|them)\s+to)\b
        | \b(?:it(?:'|’)?s\s+(?:on\s+the\s+list|done|logged|set))\b
        | \b(?:that(?:'|’)?s\s+(?:done|logged|counted))\b
      /xi

      # Promises to act NOW that were never backed by a call. Different failure
      # from a past-tense claim and just as damaging: prod message 1048 answered
      # "you didn't add it to the Harmon's category" with "Ah, gotcha. I'll fix
      # that." and called nothing. The person reads that as handled.
      #
      # Restricted to concrete, immediate promises about their data. Vague future
      # intent ("I'll keep an eye out") is conversational and deliberately absent,
      # as is anything hedged into an offer.
      #
      # See SOLICITS_INFO_RX: a promise CONDITIONAL on an answer is legitimate and
      # must not be retracted.
      ACTION_PROMISE_RX = /
        \b(?:i(?:'|’)?ll|i\s+will|let\s+me|i(?:'|’)?m\s+(?:going\s+to|gonna))\s+
          (?:go\s+)?
          (?:fix|redo|re-?add|add|update|change|rename|correct|put|move|set|log|record|mark|remove|delete)\b
        | \b(?:fixing|redoing|re-?adding|adding|updating|changing|renaming|correcting|moving|removing)\s+
          (?:that|it|those|them|this)\b
        | \b(?:on\s+it,?\s+(?:fixing|adding|updating))\b
      /xi

      # A promise is fine when it's waiting on an answer — "tell me which one and
      # I'll fix it" is the correct move on an ambiguous reference, not a broken
      # one. Only applied to promises; a past-tense claim is false whether or not
      # a question trails it.
      SOLICITS_INFO_RX = /
        \?
        | \b(?:tell\s+me|let\s+me\s+know|which\s+(?:one|item|chore|list)|remind\s+me\s+which)\b
      /xi

      # HARD CHECK: never let a reply claim it did something when nothing ran.
      #
      # The prompt covers this at length (tense discipline, the three levels), but
      # prompt rules are guidance and this one has already broken twice in prod:
      # "You got it, checking that off." against an unresolvable chore, and
      # "Timer's set for 5 minutes." with no set_timer call at all. Claiming a
      # thing happened when it didn't is the single worst failure mode for
      # something whose job is keeping a record, because there's no signal that
      # anything went wrong.
      #
      # Scope is deliberately the unambiguous case: the reply asserts completion,
      # AND nothing executed, AND there is no pending row the person can see. A
      # pending checkbox is visible on its own, so a wrong tense there is a tone
      # bug the prompt can own; this is for claims backed by nothing at all.
      def retract_false_claim!(result)
        body = @reply.body.to_s
        return if body.blank?

        kind = if body.match?(COMPLETION_CLAIM_RX)
          :claim
        elsif body.match?(ACTION_PROMISE_RX) && !body.match?(SOLICITS_INFO_RX)
          :promise
        end
        return if kind.nil?
        return if executed_anything?(result)
        return if pending_rows?(result)

        Rails.logger.warn(
          "[Buddy::GPT::Turn] retracted unbacked #{kind} on message=#{@reply.id} " \
          "user=#{@user.id}: #{body.truncate(160).inspect}",
        )
        @reply.update!(
          body:     FALLBACK_BODY,
          metadata: (@reply.metadata || {}).merge("retracted_claim" => true),
        )
      end

      # Something genuinely ran: a level-1 tool fired, or a level-2 row came back
      # executed. A "failed" or "partial" row explicitly does NOT count.
      def executed_anything?(result)
        return true if result[:auto_ran]

        buttons(result).any? { |b| b["status"].to_s == "executed" }
      end

      def pending_rows?(result)
        buttons(result).any? { |b| b["status"].to_s == "pending" }
      end

      def buttons(result)
        Array(result[:action]&.buttons)
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
