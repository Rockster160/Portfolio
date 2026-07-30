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
      # The deepest legitimate chain is look something up, act on what it found,
      # then speak. That's three rounds - but the model reliably spends one more
      # on something incidental (a set_mood, a repeat of the call it just made),
      # and hitting the cap mid-chain means it never speaks at all and the person
      # gets a filler line above their checklist. The extra round is only ever
      # spent on turns that would otherwise have ended silent; the wall-clock
      # deadline still bounds a model that's genuinely spinning.
      MAX_ROUNDS = 5

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
      # Every ack ends the same way on purpose. Once a call is answered the
      # model's only remaining job is to speak: re-issuing it produced TWO
      # complete_chore rows for one set of shelves, and level-2 rows execute on
      # arrival, so a repeat is silent double credit rather than a visible
      # duplicate.
      AGAIN = "This is recorded for this turn - do NOT call it again. Write your reply now.".freeze

      def self.ack_for(tool)
        case tool[:level]
        when 1
          { status: "done", note: "Ran immediately. Speak about it as done. #{AGAIN}" }
        when 2
          {
            status: "done_undoable",
            note:   "Ran immediately and shows as a pre-checked row the person can uncheck to undo. " \
                    "Speak about it as done. #{AGAIN}",
          }
        else
          {
            status: "proposed",
            note:   "A checkbox row is now waiting for the person to tap. It has NOT happened yet - " \
                    "do not say it's done, logged, or added. #{AGAIN}",
          }
        end
      end

      # Run the tool far enough to know whether it CAN happen, and hand that back
      # as the tool output.
      #
      # A tool's `confirm` is its resolver: it turns "shelves" into a real chore
      # or raises. ProposalBuilder used to be the first thing to call it, long
      # after the model had written its reply, so a name that matched nothing got
      # dropped in silence underneath prose already claiming credit. Resolving
      # here means the model is TOLD before it speaks.
      #
      # Nothing is executed and nothing is persisted. Every confirm in the
      # registry is a pure lookup, so ProposalBuilder re-running it later costs
      # a repeated query and nothing else.
      def self.resolve_tool(tool, call, user:, conversation:)
        resolve_call(tool, call, user: user, conversation: conversation).first
      end

      # Returns [output_for_the_model, identity_signature]. The signature is what
      # the call RESOLVED to with the volatile bits dropped, so the same chore
      # asked for twice in one turn is recognisable as a repeat even when the
      # model varies the wording or the timestamp between attempts.
      def self.resolve_call(tool, call, user:, conversation:)
        args = Buddy::Tools.normalize_function_arguments(tool, call[:arguments])
        payload, errors = Buddy::Tools.validate_payload(tool, args)
        return [resolve_failure(errors.join("; ")), nil] if errors.any?

        confirm  = tool[:confirm].call(payload, Buddy::ToolContext.new(user, conversation: conversation))
        resolved = payload.merge(confirm[:resolved] || {})

        [
          ack_for(tool).merge(resolved: confirm[:summary].to_s.presence).compact,
          [tool[:name], resolved.except(*VOLATILE_ARGS).sort_by { |k, _| k.to_s }],
        ]
      rescue StandardError => e
        [resolve_failure(e.message), nil]
      end

      # Args that describe HOW MUCH or WHEN rather than WHAT. Two calls differing
      # only in these are the model restating itself, not two real actions:
      # "just got back from a walk" produced complete_chore with `at: "now"` and
      # then again with `at: null`, and because complete_chore is level 2 both
      # would have executed - silent double credit for one walk.
      VOLATILE_ARGS = %i[count note at completed_at reply].freeze

      DUPLICATE_ACK = {
        status: "duplicate",
        note:   "You ALREADY called this in this turn and it is recorded once. This repeat was " \
                "ignored. Do not call it again - write your reply now.",
      }.freeze

      # The model has to be able to tell this apart from success, and has to know
      # that saying it happened anyway is the one unacceptable move.
      def self.resolve_failure(reason)
        {
          status: "failed",
          error:  reason.to_s.truncate(200),
          note:   "This did NOT happen and there is no checkbox for it. Do not say you did it, " \
                  "logged it, or counted it. Tell them plainly what didn't line up, and ask for " \
                  "what you need if a name was the problem.",
        }
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
      # Call, resolve, speak. Emitting a function call ENDS the model's turn - it
      # writes no text alongside one - so every call is answered and the model
      # says its piece on the round after, with the outcome in hand. A turn that
      # needs no tool never pays for a second round.
      #
      # Prose used to ride on the call itself in a `reply` field to save that
      # round. It worked, but it meant the words were written BEFORE the tool was
      # resolved, so a chore name that matched nothing got dropped in silence
      # under a sentence already claiming credit.
      #
      # Marker-era Buddy didn't have this problem because the marker was embedded
      # in the text, so words and action arrived together. Structured calls split
      # them across turns, and this loop is what stitches them back into one reply.
      def converse
        input     = History.build(@conversation, upto: @inbound)
        spoken    = nil
        proposals = []
        rounds    = 0
        @deadline = Time.current + TURN_BUDGET_SECONDS
        @failed   = Set.new
        @seen     = Set.new

        loop do
          rounds += 1
          result = run_round(input)
          # Record usage BEFORE the ok check: a failed or truncated response still
          # consumed tokens and still bills.
          record_usage(result)
          return { ok: false, error: result[:error] } unless result[:ok]

          calls      = result[:tool_calls]
          round_text = result[:text].to_s.strip
          # LAST round wins, rather than stitching every round together.
          #
          # The model is told to call first and speak after, but it often writes a
          # lead-in anyway - and then writes the real answer next round, so the
          # person got both: "Yesss, counting three more waters. Let me match that
          # up." followed by "Yessss, three waters counted." (prod 1144). They
          # aren't near-duplicates, so no text comparison catches them; they're
          # two drafts of the same reply, and only the last one had the outcome.
          spoken = round_text if round_text.present?

          # Nothing to call means the answer is already written, and a second
          # round would only cost money to re-say it. Pure conversation is a
          # ONE-call turn and always has been.
          break if calls.empty?

          # Resolve every call ONCE, here: the output goes back to the model, and
          # resolving is also what tells us whether the call is still viable.
          #
          # Repeat detection is scoped to PREVIOUS rounds. Two identical calls in
          # the SAME round are deliberate - that's how "two coffees" becomes one
          # row with count 2 - while the same call arriving a round later is the
          # model restating itself after reading the acknowledgement.
          @prior = @seen.dup
          items  = calls.flat_map { |call| call_items(call) }

          # Proposals are collected and built ONCE after the loop, so a turn can
          # never end up with two checklists attached to one reply. A call that
          # failed to resolve is excluded: ProposalBuilder would only drop it
          # again, and the model has already been told it failed, so letting it
          # count as a proposal would trip the all-discarded fallback and replace
          # a perfectly good "I couldn't find that one, which did you mean?".
          proposals.concat(calls.select { |c| proposal?(c[:name]) && @failed.exclude?(c[:call_id]) })

          break if rounds >= MAX_ROUNDS
          # Out of budget: another round would just abort on arrival. Take what
          # we have rather than burning a call to be told the same thing.
          break if Time.current > @deadline

          # A discarded lead-in is deliberately NOT fed back. Telling the model it
          # already said "let me match that up" makes it write the next round as a
          # continuation, and the person only ever sees that second half.
          input += items
        end

        { ok: true, text: spoken.to_s, proposals: proposals }
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

        result, signature = self.class.resolve_call(tool, call, user: @user, conversation: @conversation)

        if signature && @prior.include?(signature)
          @failed << call[:call_id] # excluded from proposals, same as a resolve failure
          return JSON.generate(self.class::DUPLICATE_ACK)
        end

        @seen << signature if signature
        @failed << call[:call_id] if result[:status].to_s == "failed"
        JSON.generate(result)
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
        elsif @reply.body.to_s.strip.empty?
          # Never leave a blank bubble. Running the round budget out on tool
          # calls without ever speaking is the way this happens now, and a bare
          # checklist with no words above it reads as broken, so say the minimum
          # rather than nothing.
          @reply.update!(body: nothing ? FALLBACK_BODY : "Here you go:")
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
      #
      # The last four alternatives are the HOUSE-COMMAND shape, from prod 1146:
      # "Turn the fan to low" got "Done. Fan's on low now." off a single API call
      # with no tool use anywhere and no execution to show for it. A bare "Done."
      # and a device reported in its new state are the whole tell, and neither
      # was covered. The two anchored to \A are anchored on purpose - unanchored,
      # "I can set that to low if you want" reads as a claim when it's an offer.
      COMPLETION_CLAIM_RX = /
        \b(?:check(?:ing|ed)?\s+(?:that|it|those|them|this)\s+off)\b
        | \b(?:checked\s+off|marked\s+(?:it|that|those)?\s*(?:off|done)|crossed\s+off)\b
        | \b(?:logged|recorded|credited|crediting)\b
        | \b(?:timer(?:'|’)?s\s+set|reminder(?:'|’)?s\s+set|set\s+(?:a|the)\s+timer)\b
        | \b(?:added\s+(?:it|that|them)\s+to)\b
        | \b(?:it(?:'|’)?s\s+(?:on\s+the\s+list|done|logged|set))\b
        | \b(?:that(?:'|’)?s\s+(?:done|logged|counted))\b
        | \A\s*(?:done|all\s+set|got\s+it\s+done)\b[.!,]
        | \b(?:turned|switched|flipped)\s+(?:it|that|the)\b
        | (?:\bis|\bare|(?:'|’)s)\s+(?:on|off)\s+(?:now|high|low|mid|medium)\b
        | \A\s*(?:set|setting)\s+(?:it|that|the\s+\w+)\s+to\b
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
      # The second group covers promises to WATCH for something later, which are
      # broken the same way but read as harmless. Prod message 1106 answered "can
      # you watch and let me know when the deploy finishes?" with "You got it -
      # I'll keep an eye on that." and called nothing, so the deploy came and went
      # in silence. The distinction that keeps this precise is the object: "keep
      # an eye ON <that>" names a thing and is a commitment, while "keep an eye
      # OUT" is small talk. Likewise "I'll let you know WHEN" is a promise about a
      # future event; a bare "I'll let you know" is not.
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
        | \b(?:keep(?:ing)?\s+an\s+eye\s+on)\b
        | \b(?:i(?:'|’)?(?:ll|m)\s+watch(?:ing)?\b|watching\s+for\b)
        | \b(?:i(?:'|’)?ll|i\s+will)\s+
          (?:let\s+you\s+know|tell\s+you|ping\s+you|remind\s+you|give\s+you\s+a\s+(?:heads-?up|shout))\s+
          (?:when|once|as\s+soon\s+as|the\s+(?:moment|second|minute))\b
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
