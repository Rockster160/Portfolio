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
      # The deepest legitimate chain is a prompt: list what's pending, open the
      # one they meant, submit it, then speak. That's four rounds - and the model
      # reliably spends one more on something incidental (a set_mood, a repeat of
      # the call it just made). Hitting the cap mid-chain means it never speaks
      # at all and the person gets a filler line above their checklist, so the
      # spare round is only ever spent on turns that would have ended silent. The
      # wall-clock deadline still bounds a model that's genuinely spinning.
      MAX_ROUNDS = 6

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

      QUEUED_ACK = {
        status: "queued",
        note:   "Lined up BEHIND the checkbox above, because you asked for it after something that " \
                "hasn't happened yet. It has NOT run and will not until they tap. Say it's set to " \
                "follow once they confirm - never that it's done or that anyone's been told. #{AGAIN}",
      }.freeze

      # `gate:` — the turn already produced something the person has to deal with
      # (`:rows`, a checkbox; `:forms`, an editable form) and this call came AFTER
      # it, so ProposalBuilder holds it back until that one resolves (see
      # build_steps). Prod 1201 is what this exists for: "moved it to Ours, and
      # Chelsea's in the loop now" was written about a message that went out
      # before the move it announced, and a move that hadn't happened yet.
      FORM_ACK = {
        status: "form_posted",
        note:   "A filled-in FORM is now in the thread. They can edit any value and send it. " \
                "Nothing has been submitted yet - do not say it's answered, logged, or done. " \
                "Tell them it's ready, and flag any value you were unsure of so they know what to " \
                "check. #{AGAIN}",
      }.freeze

      CHAINED_ACK = {
        status: "queued",
        note:   "Lined up BEHIND the step you asked for first. It is NOT in front of them yet - it " \
                "appears once they finish that one. Say it's next in line, never that it's ready, " \
                "waiting, or done. #{AGAIN}",
      }.freeze

      # A wait gates on the clock rather than on the person, so nothing behind it
      # needs a tap - it simply happens later. Prod 1307: "start my printer, wait
      # 1m, then preheat it for PLA" started the printer and the timer and then
      # offered to maybe do the preheat, which was the one part they'd asked for.
      WAITING_ACK = {
        status: "queued",
        note:   "Lined up BEHIND the wait you just set. It has NOT run, and nothing here needs " \
                "them - it happens on its own the moment that timer is up. Say what you'll do and " \
                "when (\"then I'll preheat it\"). Never say it's done, never say it's in progress, " \
                "and never offer it back to them as something you COULD do - it's already set to " \
                "happen. #{AGAIN}",
      }.freeze

      # A routine run is a whole sequence behind one name, so its own level says
      # nothing useful about what happened. What matters is where the sequence
      # STOPPED: everything up to the first gate has already run, and the gate
      # decides whether the rest is coming on its own or waiting on a tap.
      ROUTINE_WAITING_ACK = {
        status: "waiting",
        note:   "The routine is running. Everything up to its wait has happened; the rest goes on " \
                "its own the moment that timer is up, and needs nothing from them. Say what ran and " \
                "what's still coming (\"printer's on, and I'll preheat it once the minute's up\"). " \
                "Never offer the remaining steps back as something you COULD do. #{AGAIN}",
      }.freeze

      ROUTINE_PENDING_ACK = {
        status: "proposed",
        note:   "The routine is running, and it reached a step that needs them - a row is waiting " \
                "for a tap. Say what ran and that the rest is sitting there for them. #{AGAIN}",
      }.freeze

      ROUTINE_DONE_ACK = {
        status: "done",
        note:   "The whole routine ran, every step. Speak about it as done. #{AGAIN}",
      }.freeze

      # A rough mirror of ProposalBuilder#build_steps — accurate for the shapes
      # that actually occur (a form after a checklist, a checklist after a form,
      # a level-1 after either), and deliberately not a full re-implementation.
      # Where it's imprecise it under-claims: a second checklist reports as
      # "waiting for a tap", which is true, just of a later message.
      def self.ack_for(tool, gate: nil, opens: nil)
        return WAITING_ACK if gate == :timer
        return routine_ack(opens) if Buddy::Routines.runner?(tool)
        return QUEUED_ACK if gate && tool[:level] == 1
        return gate == :rows ? CHAINED_ACK : FORM_ACK if Buddy::Tools.form?(tool)
        return CHAINED_ACK if gate == :forms && tool[:level] == 3

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

      def self.routine_ack(opens)
        case opens
        when :timer         then ROUTINE_WAITING_ACK
        when :rows, :forms  then ROUTINE_PENDING_ACK
        else                     ROUTINE_DONE_ACK
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
      # The kind of unbacked assertion a body makes, or nil. Shared by the
      # corrective round, the retraction, and the eval harness, so none of them
      # can disagree about what counts as a claim. Defined here rather than
      # inline because the regexes live below `private` and the predicate is a
      # pure function of the text.
      def self.unbacked_claim(body)
        return nil if body.blank?
        return :claim if body.match?(COMPLETION_CLAIM_RX)
        return :promise if body.match?(ACTION_PROMISE_RX) && !body.match?(SOLICITS_INFO_RX)

        nil
      end

      def self.resolve_tool(tool, call, user:, conversation:, gate: nil)
        resolve_call(tool, call, user: user, conversation: conversation, gate: gate).first
      end

      # Which kind of gate this call opens, or nil when it isn't one. A wait
      # depends on the ARGUMENTS rather than the tool: the same set_timer is an
      # ordinary countdown without `then_continue`.
      #
      # A routine run stands in for the steps it names, so its gate is the first
      # gate among THOSE — a routine with a wait in it holds the rest of the
      # turn back exactly as the same calls made by hand would.
      def self.gate_kind_for(tool, payload={}, user: nil)
        steps = (Buddy::Routines.expand(user, tool, payload) if user)
        return steps.filter_map { |m| gate_kind_for(Buddy::Tools[m[:tool_name]], m[:payload]) }.first if steps

        return :timer if Buddy::Tools.waits?(tool, payload)
        return :forms if Buddy::Tools.form?(tool)

        :rows if tool[:level] == 3
      end

      # Returns [output_for_the_model, identity_signature, gate_kind]. The
      # signature is what the call RESOLVED to with the volatile bits dropped, so
      # the same chore asked for twice in one turn is recognisable as a repeat
      # even when the model varies the wording or the timestamp between attempts.
      def self.resolve_call(tool, call, user:, conversation:, gate: nil)
        # The schema was never offered, so getting here means the model invented
        # the name. Reads as "doesn't exist" rather than "you're not allowed",
        # because for this person it doesn't.
        unless Buddy::Features.allows_tool?(user, tool)
          return [resolve_failure("#{tool[:name]} isn't something this person has set up"), nil, nil]
        end

        args = Buddy::Tools.normalize_function_arguments(tool, call[:arguments])
        payload, errors = Buddy::Tools.validate_payload(tool, args, zone: Buddy::Day.zone(user))
        return [resolve_failure(errors.join("; ")), nil, nil] if errors.any?

        # A core tool reaching into a feature this person doesn't have, via an
        # option that was trimmed out of the schema (remind_when's chore
        # trigger). Same treatment as a tool that doesn't exist for them.
        if (gated = Buddy::Features.gated_arg(user, tool, payload))
          return [resolve_failure("#{tool[:name]} can't watch for #{gated.first} #{payload[gated.first]} - that isn't part of this person's setup"), nil, nil]
        end

        ctx = Buddy::ToolContext.new(user, conversation: conversation)
        opens = gate_kind_for(tool, payload, user: user)
        # A form tool's confirm is its PRE-SUBMIT gate and runs when they send,
        # so running it here would reject a form for being incomplete — which is
        # the entire point of showing them one. Its `fields` proc is the resolver
        # instead: it raises the same way when the thing being edited is gone.
        if Buddy::Tools.form?(tool)
          fields = Buddy::FormFields.normalize(tool[:form][:fields].call(payload, ctx))
          raise "nothing to fill in for that one" if fields.empty?

          signature = [tool[:name], payload.except(*VOLATILE_ARGS).sort_by { |k, _| k.to_s }]
          return [ack_for(tool, gate: gate, opens: opens), signature, opens]
        end

        confirm  = tool[:confirm].call(payload, ctx)
        resolved = payload.merge(confirm[:resolved] || {})

        [
          ack_for(tool, gate: gate, opens: opens).merge(resolved: confirm[:summary].to_s.presence).compact,
          [tool[:name], resolved.except(*VOLATILE_ARGS).sort_by { |k, _| k.to_s }],
          opens,
        ]
      rescue StandardError => e
        [resolve_failure(e.message), nil, nil]
      end

      # Args that describe HOW MUCH or WHEN rather than WHAT. Two calls differing
      # only in these are the model restating itself, not two real actions:
      # "just got back from a walk" produced complete_chore with `at: "now"` and
      # then again with `at: null`, and because complete_chore is level 2 both
      # would have executed - silent double credit for one walk.
      #
      # `note` is deliberately NOT here: it's part of WHAT was recorded, not how
      # much or when. "Log 2 water as Hint Raspberry, then 3 without a note" is
      # two genuinely different completions, and dropping note from the signature
      # collapsed the second into a duplicate of the first - three waters that
      # never happened while the reply claimed they did (prod 2440). Re-noting the
      # SAME completion goes through edit_chore_completion, so a differing note
      # here always means a distinct action.
      VOLATILE_ARGS = %i[count at completed_at reply].freeze

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

      FALLBACK_BODY = "Hmm, I don't quite follow - can you give me a little more to go on?".freeze

      # The model leads a reply with `[[mood:NAME]]` to set its face as the words
      # land (see the persona's "Your face"). Only a LEADING mood marker is the
      # supported protocol; it's parsed, applied, and stripped in finalize before
      # the body broadcasts, so the expression reaches the screen first.
      LEADING_MOOD_RX = /\A\s*\[\[\s*mood\s*:\s*([a-z_]+)\s*\]\]\s*/i

      # Defensive. A leading mood marker is consumed before this ever runs, so a
      # marker reaching here is stray — a mood marker the model buried mid-text,
      # or residue of some other retired `[[x:y]]`. We strip it rather than show
      # brackets to the person, and log it.
      STRAY_MARKER_RX = /\[\[\s*[a-z_]+\s*:[^\]]*\]\]/i

      # The bracketed attribution Buddy::GPT::History puts on a bridged message
      # so Buddy can tell whose words a line is. It is INPUT framing and the
      # prompt says so outright, so the model writing one means it is imitating
      # the SHAPE of a past relay instead of calling message_partner.
      #
      # Prod 1439/1440: "Tell Chelsea: Rude. Byte took away my formatting!" came
      # back as "Sent. 😅\n\n[you passed this along to Moss] Rude. Byte took away
      # my formatting!" with no tool call, no relay row, and no receipt chip.
      # Nothing reached Chelsea and nothing said so.
      RELAY_FRAMING_RX = /\[(?:you\s+passed\s+this\s+along\s+to|relayed\s+to\s+you\s+from)\s[^\]\n]{0,40}\]/i

      def self.run!(message, client: nil)
        new(message, client: client).run!
      end

      def initialize(message, client: nil)
        @inbound      = message
        @conversation = message.byte_conversation
        @user         = @conversation.user
        @client       = client || Client.new
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
        # Set to the kind of the turn's FIRST gate (:rows / :forms) once one
        # resolves; everything asked for after that point is queued behind it
        # rather than going out with this reply.
        @gate_kind = nil
        nudged     = false

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

          if calls.empty?
            # Nothing to call usually means the answer is already written, and a
            # second round would only cost money to re-say it. Pure conversation
            # is a ONE-call turn and always has been.
            #
            # The exception is a reply that CLAIMS an action nothing backs up.
            # Prod 1151 answered "Set the fan to high" with a finished-sounding
            # line off a single call, no tools, no reasoning. Retracting that is
            # honest but useless - the person asked for a thing and got a shrug.
            # It is far likelier the model skipped the call than that it meant
            # the claim, so it gets exactly one corrective round to make it.
            nudge = nudge_for(proposals, spoken, nudged, rounds)
            break if nudge.nil?

            nudged = true
            input += [{ role: :developer, content: nudge }]
            next
          end

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
      #
      # `staged_input` is for what an output CAN'T carry: it's a string, and
      # view_image's whole job is to put pixels back in front of the model. The
      # tool stages a user item and we splice it in behind the output it belongs
      # to. Empty for every other call.
      def call_items(call)
        output = tool_output(call)
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
            output:  output,
          },
          *staged_input,
        ]
      end

      def staged_input
        read_tools.values.flat_map { |reader|
          reader.respond_to?(:drain_input) ? reader.drain_input : []
        }
      end

      # Tools that ANSWER the model instead of acting for the person. Their
      # output goes back as function_call_output and the loop runs another
      # round, which is also why they must stay out of Buddy::Tools: proposal?
      # counts every registry tool as a checklist row, and reading state should
      # never put a checkbox in front of anyone.
      def read_tools
        @read_tools ||= {
          ContextTool::NAME  => ContextTool.new(@user, @conversation),
          PromptTool::NAME   => PromptTool.new(@user, @conversation),
          ImageTool::NAME    => ImageTool.new(@user, @conversation),
          ListenerTool::NAME => ListenerTool.new(@user, @conversation),
        }
      end

      def tool_output(call)
        name = call[:name].to_sym
        reader = read_tools[name]
        return reader.call(call[:arguments]) if reader
        # Silent tools already ran as their call arrived (see run_round).
        return JSON.generate({ ok: true }) if Buddy::SideEffects.handles?(name)

        tool = Buddy::Tools[name]
        return JSON.generate({ ok: false, error: "no tool named #{name}" }) if tool.nil?

        result, signature, opens = self.class.resolve_call(
          tool, call, user: @user, conversation: @conversation, gate: @gate_kind,
        )

        if signature && @prior.include?(signature)
          @failed << call[:call_id] # excluded from proposals, same as a resolve failure
          return JSON.generate(self.class::DUPLICATE_ACK)
        end

        @seen << signature if signature
        @failed << call[:call_id] if result[:status].to_s == "failed"
        # Set AFTER this call's ack, so the gating call itself isn't described as
        # queued behind itself, and only ONCE — the first gate is the one the
        # person meets, and everything the model asks for after it waits on that,
        # matching how ProposalBuilder actually splits them.
        @gate_kind ||= opens if result[:status].to_s != "failed"
        JSON.generate(result)
      end

      def proposal?(name)
        Buddy::Tools.known?(name)
      end

      RETRY_NUDGE = <<~TXT.freeze
        STOP. The reply you just wrote says you did something, but you called no
        tool, so nothing happened and there is nothing for the person to tap.

        Do ONE of these now:
        - If the thing is doable, call the tool. Check `jil_functions` and
          `jil_triggers` before deciding you can't - a fan, light, scene, or car
          command usually lives in one of them.
        - If it genuinely isn't doable, say so plainly and say what you'd need.

        Do not repeat the claim.
      TXT

      POINTER_NUDGE = <<~TXT.freeze
        STOP. Your whole reply is a lead-in pointing at something, and you called
        no tool, so there is nothing underneath it. The person is looking at a
        sentence that promises a list or an answer and then just ends.

        Do ONE of these now:
        - If a tool produces the thing you were pointing at, call it. Listing
          their reminders, their lists, their prompts - each of those is a tool
          call, not a sentence.
        - If you meant to say the thing yourself, say it. In full, in this reply.

        A lead-in is never the whole message.
      TXT

      NOTIFY_NUDGE = <<~TXT.freeze
        STOP. Nobody spoke to you. Something fired, and your reply is the whole
        notification - the only thing that reaches them. What you just wrote
        tells them there is nothing to hear, so the thing that fired never gets
        mentioned at all.

        A trigger that reads exactly like an earlier one is a SECOND occurrence,
        not a repeat. Deploys finish again; recurring reminders come back around.

        Write the notification now: what just happened, in your voice.
      TXT

      # A self-initiated reply that decides the news is old. Prod 1319: a second
      # deploy tripped the same watch 45 minutes after the first, and since both
      # seeds read identically the model found its own announcement of the first
      # one in history and answered "Already handled that one just now. Nothing
      # new is waiting on my side." That went out as the push.
      #
      # Only ever consulted on a self-initiated turn - answering a person with
      # "already did that" is often the honest reply.
      DISMISSAL_RX = /
        \b(?:
          already \s+ (?:handled|covered|sent|told|did|done|mentioned|passed|flagged|pinged|got) \b |
          nothing \s+ (?:new|else|more) \b |
          nothing \s+ (?:to|left \s+ to) \s+ (?:report|add|pass|tell|say) \b |
          no \s+ (?:new \s+)? (?:updates?|news) \b
        )
      /xi

      # A reply that is NOTHING BUT a pointer at output that was never rendered.
      # Prod 1313 answered "which reminders do I have set up?" with "Here's what
      # you've got." and no call - `list_reminders`' own description had handed
      # the model that exact sentence as the lead-in to write, and it wrote the
      # lead-in instead of making the call.
      #
      # Anchored at both ends and allowing no clause break, so it only fires on a
      # reply that IS the pointer. "Here's the thing, I can't do that from here"
      # and "Here's what I'd do: skip it" both carry a real second clause and are
      # left alone.
      DANGLING_POINTER_RX = /
        \A
        (?:here(?:'|’)?s | here\s+(?:is|are) | these\s+are | below\s+(?:is|are))
        \s+ [^,.:;!?]{0,60} [.:!]? \s*
        \z
      /xi

      # Worth a corrective round: nothing was proposed, we haven't already spent
      # the one retry we allow, and the reply either claims an action, points at
      # output that isn't there, or waves off news nobody has heard yet. Returns
      # the nudge to send, or nil.
      def nudge_for(proposals, spoken, nudged, rounds)
        return nil if nudged || proposals.any?
        return nil if rounds >= MAX_ROUNDS || Time.current > @deadline
        return NOTIFY_NUDGE if self_initiated? && spoken.to_s.match?(DISMISSAL_RX)
        return RETRY_NUDGE if unbacked_claim(spoken.to_s).present?
        return POINTER_NUDGE if spoken.to_s.strip.match?(DANGLING_POINTER_RX)

        nil
      end

      def unbacked_claim(body)
        self.class.unbacked_claim(body)
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
          ContextTool.schema(user: @user),
          PromptTool.schema,
          ImageTool.schema,
          ListenerTool.schema,
          *Buddy::SideEffects.function_schemas(theme: @conversation.buddy_theme),
          *Buddy::Tools.function_schemas(user: @user),
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
          pet_expression:              @conversation.buddy_expression.presence || Buddy::Faces.default.to_s,
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

      # The hidden seed CompanionDelivery#deliver_prompt writes to make Buddy
      # speak unprompted. `true` or nil rather than false, so `.compact` keeps
      # the flag off ordinary replies instead of stamping every one of them.
      def self_initiated?
        meta = @inbound.metadata
        return nil unless meta.is_a?(Hash) && meta["kind"].to_s == "buddy_trigger"

        true
      end

      # ---- message lifecycle -------------------------------------------------

      def create_reply
        msg = @conversation.byte_messages.create!(
          user:      @user,
          direction: :inbound,
          state:     :streaming,
          body:      PLACEHOLDER,
          metadata:  {
            "kind"        => "buddy",
            "in_reply_to" => @inbound.id,
            # Buddy speaking on its OWN initiative rather than answering: a
            # reminder firing, a watch tripping, the morning briefing. Carried
            # onto the reply because by the time ByteNotifier sees it, the hidden
            # seed that started it is out of scope — and a nudge nobody asked for
            # is exactly the one that must not be swallowed by presence.
            "self_initiated" => self_initiated?,
          }.compact,
        )
        broadcast(msg)
        msg
      end

      def finalize_success(outcome)
        body = display_body(apply_leading_mood(outcome[:text]))
        @reply.update!(state: :delivered, body: body, delivered_at: Time.current)

        proposals = outcome[:proposals]
        result    = build_proposals(proposals)
        nothing   = result[:action].nil? && !result[:auto_ran] && Array(result[:forms]).empty?

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
        | \b(?:saved\s+(?:it|that|as)|(?:it|that)(?:'|’)?s\s+saved|now\s+runs)\b
        | \b(?:running|firing)\s+(?:\*\*|`)[^*`\n]{1,60}(?:\*\*|`)
        # Prod 2054: "Print again" got "Yep. Running the last print again." and
        # then, when told it hadn't, "Yep, it's running again now." — neither
        # turn called anything. The emphasised form above only catches the
        # receipt shape ("Firing **Fan High**"); a plain-prose claim walked
        # straight past it, twice, and the person had to notice on their own.
        #
        # `running` on its own is far too common to match ("running late",
        # "running low", "the dishwasher is running"), so this is anchored to
        # the START of the reply and requires an object right after the verb.
        # Both halves are load-bearing; the turn spec carries the
        # false-positive list they exist to protect.
        # (No slashes in these comments - inside a regex literal, even an
        # extended-mode comment ends at one.)
        | \A\s*(?:yep|yeah|yes|sure|ok(?:ay)?|on\s+it|got\s+it)?[\s\-—:.,!]*
            (?:running|re-?running|firing|kicking\s+off)\s+(?:it|that|the|your|another)\b
        | \b(?:it|that)(?:'|’)?s\s+(?:running|firing)\s+(?:again|now)\b
        | \bi(?:'|’)?m\s+(?:running|re-?running|firing)\s+(?:it|that|the|your)\b
        | \b(?:counted|counting)\s+(?:it|that|those|them|\*\*|\d)
        | \A\s*sent\b[.!,]
        | \b(?:passed|sent)\s+(?:it|that|this|them|those)\s+(?:along|on|over|to)\b
        | \b(?:told|messaged|pinged|texted)\s+(?:her|him|them)\b
        | \bin\s+the\s+loop\s+now\b
        | \b(?:she|he|they)\s+(?:knows?|has\s+it)\s+now\b
        | #{RELAY_FRAMING_RX}
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
        kind = unbacked_claim(body)
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

      # A posted form is a pending row in every sense that matters here: it's
      # visible, it's waiting on them, and the reply above it is allowed to say
      # so without being retracted.
      def pending_rows?(result)
        return true if Array(result[:forms]).any?

        buttons(result).any? { |b| b["status"].to_s == "pending" }
      end

      def buttons(result)
        Array(result[:action]&.buttons)
      end

      def build_proposals(proposals)
        return { action: nil, auto_ran: false, forms: [] } if proposals.empty?

        markers = proposals.flat_map { |call|
          tool    = Buddy::Tools[call[:name]]
          payload = Buddy::Tools.normalize_function_arguments(tool, call[:arguments])
          # A routine run is a stand-in for the steps it names. Swapping it here,
          # rather than letting it execute and fan out on its own, means the
          # steps reach ProposalBuilder as ordinary markers — so they order,
          # gate, and wait exactly like the same calls typed out by hand.
          Buddy::Routines.expand(@user, tool, payload) ||
            [{ tool_name: call[:name], payload: payload }]
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

      # A leading `[[mood:NAME]]` is the model setting its face for THIS reply.
      # Apply it here — before the body is broadcast, so the expression reaches
      # the screen ahead of the words — and strip it off the front so the person
      # never sees the brackets. apply_mood validates the face against the theme
      # and no-ops on an unchanged or unrenderable one, so a bad marker just
      # vanishes. The set_mood tool remains the fallback when the model didn't
      # (or couldn't) lead with a marker.
      def apply_leading_mood(text)
        raw   = text.to_s
        match = raw.match(LEADING_MOOD_RX)
        return raw if match.nil?

        Buddy::SideEffects.apply_mood(@conversation, match[1])
        raw.sub(LEADING_MOOD_RX, "")
      end

      # Framing the model was given to READ and echoed back into what it SAYS.
      # Both get stripped rather than shown, and both get logged: a marker means
      # some prompt section still teaches the retired protocol, and a relay
      # bracket means Buddy imitated a bridged message instead of sending one.
      def display_body(text)
        raw   = text.to_s
        stray = { marker: STRAY_MARKER_RX, relay: RELAY_FRAMING_RX }.select { |_kind, rx| raw.match?(rx) }
        return raw.strip if stray.empty?

        stray.each { |kind, rx| Rails.logger.warn("[Buddy::GPT::Turn] stray #{kind} in output: #{raw[rx]}") }
        stray.each_value.reduce(raw) { |body, rx| body.gsub(rx, "") }.gsub(/\n{3,}/, "\n\n").strip
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
