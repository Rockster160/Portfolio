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

        confirm   = tool[:confirm].call(payload, ctx)
        resolved  = payload.merge(confirm[:resolved] || {})
        signature = [tool[:name], resolved.except(*VOLATILE_ARGS).sort_by { |k, _| k.to_s }]

        # An answering tool runs HERE, and what comes back IS the output. It
        # opens no gate: nothing is waiting on the person, and nothing follows
        # it in the checklist because it never becomes one (see Turn#proposal?).
        return [answer_output(tool, resolved, ctx), signature, nil] if Buddy::Tools.answers?(tool)

        [
          ack_for(tool, gate: gate, opens: opens).merge(resolved: confirm[:summary].to_s.presence).compact,
          signature,
          opens,
        ]
      rescue StandardError => e
        [resolve_failure(e.message), nil, nil]
      end

      # The `note` is the whole safeguard: an ordinary level-1 ack tells the
      # model its call is "done", and a model told a LOOKUP is done with nothing
      # to show for it writes the answer it expected to get.
      #
      # It deliberately does NOT forbid calling again. A print handed a name the
      # printer rejects has to be retried with the corrected one, and that is a
      # different call. What's pointless is repeating it UNCHANGED, which the
      # signature guard already catches on its own (see DUPLICATE_ACK).
      ANSWER_NOTE = "This ran, and what's above is what came back. Speak from what is " \
                    "actually there - if it came back empty, or refused, that IS the " \
                    "outcome, so say so rather than describing what you expected. Asking " \
                    "again with the same arguments will only return the same thing.".freeze

      # `status` and `note` are applied AFTER the tool's own data, not before.
      # They're the frame around the answer rather than part of it, and a tool
      # returning a key of its own by either name would otherwise silently
      # overwrite the flag the model reads to know the lookup even succeeded.
      # read_idea did exactly that on its first outing: it reported the idea's
      # own status, so a perfectly good lookup came back as `status: "active"`,
      # which reads as a plausible value rather than as a broken one.
      def self.answer_output(tool, payload, ctx)
        outcome = Buddy::Tools.dispatch(tool, payload, ctx)
        return resolve_failure(outcome[:error]) unless outcome[:ok]
        return resolve_failure("#{tool[:name]} returned nothing readable") unless outcome[:data].is_a?(Hash)

        outcome[:data].merge(status: :answered, note: ANSWER_NOTE)
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
      #
      # The second half is about RECOVERY, and it exists because the recovery
      # reached for was destructive. Prod 3434 and 3436: an hourly repeat that
      # schedule_reminder couldn't parse came back "Oop, that repeat shape
      # didn't line up!" over a cancel_reminder row for the very reminder it had
      # been trying to change - and the second attempt offered to remove the
      # standing daily one alongside it. She'd said "Perfect!" to what she
      # thought was the repeat being set; tapping through would have deleted a
      # reminder she relies on. A failed call changed nothing, so the record is
      # still exactly right and there is nothing to clean up.
      def self.resolve_failure(reason)
        {
          status: "failed",
          error:  reason.to_s.truncate(200),
          note:   "This did NOT happen and there is no checkbox for it. Do not say you did it, " \
                  "logged it, or counted it. Tell them plainly what didn't line up, and ask for " \
                  "what you need if a name was the problem. Nothing changed, so do NOT offer to " \
                  "delete, cancel or remove anything as a way out of it - the record you were " \
                  "editing is untouched and still wanted. Fix the arguments and call again, or ask.",
        }
      end

      # The bubble minted at turn start, which the client renders as a live pulsing
      # placeholder — that IS the typing indicator. Its body is replaced once, with
      # the finished reply. Buddy answers in 1-3 sentences in about a second, so
      # there's nothing worth animating in between.
      PLACEHOLDER = "…".freeze

      FALLBACK_BODY = "Hmm, I don't quite follow - can you give me a little more to go on?".freeze

      # What to say instead when a COMMAND went unanswered. The generic fallback
      # is wrong here: it reads as not having understood, and the request was
      # perfectly clear - we just didn't do it. Owning that is the whole point,
      # since the alternative is them believing the TV is off.
      UNDONE_BODY = "Ah - I said that like it was done, and it wasn't. Nothing actually ran. " \
                    "Want me to have another go at it?".freeze

      # What to say when the row is REAL and only the tense was wrong.
      #
      # Distinct from UNDONE_BODY on purpose: nothing was fabricated here, the
      # thing is built and sitting on screen waiting to be tapped, so throwing
      # the reply away would be as wrong as leaving the claim standing.
      PENDING_BODY = "Almost - I've got that ready right below, it just needs your tap.".freeze

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
        input    += [{ role: :developer, content: routine_directive }] if routine_directive
        spoken    = nil
        proposals = []
        rounds    = 0
        @deadline = Time.current + TURN_BUDGET_SECONDS
        @failed   = Set.new
        @seen     = Set.new
        @acted    = false
        # Set to the kind of the turn's FIRST gate (:rows / :forms) once one
        # resolves; everything asked for after that point is queued behind it
        # rather than going out with this reply.
        @gate_kind = nil
        # Whether this turn READ `recent_actions` rather than answering about
        # its own doings from memory. See disputed_action?.
        @read_actions = false
        # Whether any round reached for `run_routine`. See forced_routine.
        @asked_routine = false
        # Whether anything got put on the clock this turn. See tool_output.
        @scheduled     = false
        nudged         = false

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
          # Whether the model REACHED for a routine at all, which is a different
          # question from whether one ended up in `proposals`: a call that
          # failed to resolve is dropped from those, and that failure is the
          # all-or-nothing guarantee doing its job rather than a gap to fill.
          @asked_routine ||= calls.any? { |c| Buddy::Routines.runner?(Buddy::Tools[c[:name]]) }

          # Whether anything in this round PUT SOMETHING ON THE CLOCK, asked
          # before any of it runs. "Remind me at 5 to call mom, and add milk to
          # the list" names a time and then asks for something now, and which of
          # the two calls the model emits first is arbitrary — read one at a
          # time, the reminder only covered the milk when it happened to come
          # first. Reading the whole round covers it either way.
          @scheduled ||= calls.any? { |c| self.class.defers?(c[:name], c[:arguments]) }

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

        { ok: true, text: spoken.to_s, proposals: forced_routine(proposals) }
      end

      # ---- a message that IS a routine's name ---------------------------------

      # The saved sequence, when what they said was its name and nothing else.
      # Memoized because both the directive and the guarantee want it, and
      # `defined?` rather than `||=` so a nil answer is asked for once.
      def outright_routine
        return @outright_routine if defined?(@outright_routine)

        @outright_routine = Buddy::Routines.named_outright(@user, @inbound.body)
      end

      ROUTINE_DIRECTIVE = <<~TXT.freeze
        What they just said IS the name of their saved routine **%<name>s**, on its own. Call `run_routine` with that exact name and let the whole sequence run, then say your piece over it. Doing the steps by hand instead drops the ones you don't think of, and answering conversationally without running it drops all of them.
      TXT

      def routine_directive
        return nil if outright_routine.nil?

        format(ROUTINE_DIRECTIVE, name: outright_routine.name)
      end

      # A routine named outright RUNS, whatever the turn decided to do instead.
      #
      # The directive above asks, and asking is where this failed before: the
      # name was sitting in the prompt under "Routines they've saved" and
      # matching it was left to the model reading it, so one night "Good night"
      # came back as a warm goodnight with nothing run (prod 3392). The follow-up
      # request got the monitors dark by hand and the scene never ran at all,
      # which is the shape of the whole problem - half a routine looks like a
      # working one.
      #
      # So the improvised proposals are REPLACED rather than added to. The
      # message was the name and nothing else, so there was nothing else in it
      # to act on, and the saved sequence is what the person asked for by
      # definition.
      #
      # Two things call it off. A turn that already REACHED for `run_routine` is
      # left exactly as it is, whether the call worked or not: a routine that
      # can't run any more fails there deliberately, and forcing it afterwards
      # would step over that and run the half of it that still resolves. And a
      # routine that can't run isn't forced in the first place - `check_runnable!`
      # is the all-or-nothing guarantee, and skipping it here would give a
      # rotten routine one path that runs it in pieces.
      def forced_routine(proposals)
        return proposals if outright_routine.nil? || @asked_routine
        return proposals if proposals.any? { |c| Buddy::Routines.runner?(Buddy::Tools[c[:name]]) }

        Buddy::Routines.check_runnable!(outright_routine, Buddy::ToolContext.new(@user, conversation: @conversation))
        # `run_routine`'s confirm is what normally counts a run, and forcing the
        # call skips straight past it to the expansion in build_proposals.
        outright_routine.touch_run!
        [{
          name:      Buddy::Routines::RUNNER,
          arguments: { name: outright_routine.name },
          call_id:   "forced-routine-#{outright_routine.id}",
        }]
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] #{outright_routine.name} named outright but can't run: #{e.message}")
        proposals
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

          # A side effect that really moved something counts as having acted,
          # exactly like an acting answering tool. Without this, `sort_stash`
          # refiling a stashed idea was invisible to the retraction guard, and
          # a truthful "moved it to home" was one regex away from being wiped
          # as an unbacked claim.
          @acted = true if Buddy::SideEffects.call(@conversation, event[:name], event[:arguments])
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
          ContextTool::NAME  => ContextTool.new(@user, @conversation, briefing: today_briefing?),
          PromptTool::NAME   => PromptTool.new(@user, @conversation),
          ImageTool::NAME    => ImageTool.new(@user, @conversation),
          ListenerTool::NAME => ListenerTool.new(@user, @conversation),
        }
      end

      def tool_output(call)
        name = call[:name].to_sym
        # Announced BEFORE the work, not after: an answering tool runs inside
        # this method, so a line posted afterwards would describe something
        # already finished and the slowest part of the turn would still look
        # like nothing was happening.
        note_progress(name, call[:arguments])
        @read_actions ||= name == ContextTool::NAME && ContextTool.serves?(call[:arguments], :recent_actions)
        reader = read_tools[name]
        return reader.call(call[:arguments]) if reader
        # Silent tools already ran as their call arrived (see run_round).
        return JSON.generate({ ok: true }) if Buddy::SideEffects.handles?(name)

        tool = Buddy::Tools[name]
        return JSON.generate({ ok: false, error: "no tool named #{name}" }) if tool.nil?

        # THE gate, and it has to be HERE: an acting answering tool runs inside
        # `resolve_call` (see its `answers?` branch), so anywhere downstream is
        # after the sound has already played. Every call passes through this
        # method — the proposal path too — so one check covers both, and a call
        # marked failed is excluded from `proposals` by the same line that drops
        # one which couldn't resolve.
        if deferred_command? && Buddy::Tools::IMMEDIATE_ACTION_TOOLS.include?(name) && !@scheduled
          Rails.logger.warn(
            "[Buddy::GPT::Turn] held back #{name} on message=#{@inbound.id} " \
            "user=#{@user.id}: the request named a time",
          )
          @failed << call[:call_id]
          return JSON.generate(self.class.held_for_later(name))
        end

        result, signature, opens = self.class.resolve_call(
          tool, call, user: @user, conversation: @conversation, gate: @gate_kind
        )

        if signature && @prior.include?(signature)
          @failed << call[:call_id] # excluded from proposals, same as a resolve failure
          return JSON.generate(self.class::DUPLICATE_ACK)
        end

        @seen << signature if signature
        @failed << call[:call_id] if result[:status].to_s == "failed"
        # "Do this now and that at 11" is a real sentence. Once the model has
        # actually put something on the clock this turn, it has understood the
        # time, and an immediate call after that is a second request rather than
        # the mistake this guards against. The round-level read above catches
        # the same thing a call earlier; this one adds the half that can only be
        # known afterwards, that the scheduling call really resolved.
        @scheduled = true if result[:status].to_s != "failed" && self.class.defers?(name, call[:arguments])
        # An acting answering tool already did the thing, right here, and will
        # never be seen by ProposalBuilder. Recording it is what stops the
        # retraction from treating a true "Fan's on low now." as unbacked.
        @acted = true if result[:status].to_s != "failed" && Buddy::Tools.acts?(tool)
        # Set AFTER this call's ack, so the gating call itself isn't described as
        # queued behind itself, and only ONCE — the first gate is the one the
        # person meets, and everything the model asks for after it waits on that,
        # matching how ProposalBuilder actually splits them.
        @gate_kind ||= opens if result[:status].to_s != "failed"
        JSON.generate(result)
      end

      # An answering tool already ran in tool_output and reported there, so it
      # must not also be collected as a proposal — ProposalBuilder would run it
      # a second time, which for a lookup is a wasted query and for a print is
      # a second print.
      def proposal?(name)
        Buddy::Tools.known?(name) && !Buddy::Tools.answers?(Buddy::Tools[name])
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

      # Does the reply actually open with a hello?
      #
      # Deliberately generous — a false "missing" costs one extra round, while
      # being strict about the wording would fight the instruction to vary it.
      # Leading emoji and punctuation are skipped; the stretched spellings the
      # tone profiles ask for (`Mooooorning!`, `Hellooooooo`, `Hiii`) all have to
      # pass, which is why every vowel here is repeatable.
      GREETING_OPENER_RX = /
        # Skip anything that isn't a letter rather than naming the categories:
        # a leading "☀️" is a symbol AND a variation selector, and listing the
        # parts of an emoji is a losing game.
        \A\P{L}*
        # "Well hello" is on Byte's own list of openers, so a short lead-in word
        # in front of the hello can't disqualify it.
        (?:(?:well|ah+|oh+|ok(?:ay)?)[\s,]+)?
        (?:
          # The dropped `g` matters more than it looks: a hello this misses is
          # one the fallback puts a SECOND hello in front of.
          #
          # The trailing lookahead is what stops the NOUN reading as the
          # greeting. Prod 3650 opened "Morning's pretty light on your side"
          # and satisfied this: `m+o+r+n+i+n+` took "Mornin", `g+` took the
          # "g", and nothing required the word to end there — so a briefing
          # with no hello in it kept the fallback from adding one. `\b` won't
          # do, since an apostrophe is already a word boundary. Only the
          # time-of-day arms need it: they're the ones that are ordinary
          # nouns, and "Happy Friday's here" should still count as a hello.
            (?:good\s+)? m+o+r+n+i+n+ (?:g+|['’]) (?!['’]?\w)
          | (?:good\s+)? (?:afternoon|evening|evenin['’]|night) (?!['’]?\w)
          | h+e+y+
          | h+i+\b
          | h+e+l+l+o+
          | howdy | howzit | greetings | welcome\s+back | ah+oy | yo\b
          | happy\s+\w+
        )
      /xi

      # Put the hello on, when the model didn't.
      #
      # This is the fifth attempt and the first one that isn't a request. Four
      # paragraphs of prompt, then a shorter directive, then the whether-to
      # judgement moved into Rails, then a corrective round that said STOP in
      # capitals — and prod 3398 still opened "Light day on your side so far."
      # The corrective round can't be relied on either: it's one shot shared
      # with five other arms (nudge_for), so a briefing that trips any of them
      # first never gets asked, and a model that ignores it isn't asked twice.
      #
      # So the words come from the pet's own table (Buddy::VoiceLines) and are
      # simply put in front. The model still writes its own whenever it does —
      # this only fills a silence, and `unlike:` keeps it off the hello the last
      # briefing used.
      #
      # The line's mood is deliberately NOT applied. The model already chose a
      # face for this reply, and overwriting a deliberate expression to deliver
      # a hello is the wrong trade.
      def with_greeting(body)
        return body unless greeting_missing?(body)

        line = Buddy::VoiceLines.pick(
          @conversation.buddy_theme,
          Buddy::TodayBriefing.greeting_kind(@user),
          unlike: previous_briefing_body
        )
        return body if line[:text].blank?

        "#{line[:text]} #{body}"
      rescue StandardError => e
        # A missing hello is a worse briefing; a raised exception here is no
        # briefing at all.
        Rails.logger.warn("[Buddy::GPT::Turn] greeting fallback failed: #{e.class}: #{e.message}")
        body
      end

      # What this thread was told last time, so the same opener doesn't land two
      # mornings running.
      def previous_briefing_body
        @conversation.byte_messages
          .where(direction: :inbound)
          .where("byte_messages.metadata ->> 'self_initiated' = 'true'")
          .where.not(id: @reply.id)
          .order(id: :desc)
          .limit(1)
          .pick(:body)
      end

      # A briefing that announces itself instead of being itself.
      #
      # "Hiii! Your Today is ready ✨" is not a briefing, it's a claim that one
      # happened — and nothing else is coming, so the person is left with a
      # receipt for a message that was never written. It shows up two ways: the
      # `today_briefing` tool used to be callable from the briefing turn (see
      # Buddy::Tools::BRIEFING_WITHHELD), and once one reply lands like this it
      # sits in history teaching every briefing after it.
      #
      # That second half is why the seed's HARD NO isn't enough on its own. A
      # thread that has said it once has a worked example in front of it, and
      # prose has lost to a worked example every time it's been tried here.
      #
      # A REPAIR, in the same spirit as with_greeting: the claim is cut and
      # whatever real briefing followed it stands. Only when nothing is left does
      # this report — that's a briefing that never got written, and it should be
      # loud rather than silently empty.
      # Matches the CLAIM, not the sentence around it. An earlier cut anchored
      # to the start of a line and "Hiii! Your Today is ready" walked straight
      # past it; taking the whole sentence instead would have eaten the real
      # briefing in "…went out 💛 Dentist at 2".
      #
      # The state word has to follow the noun almost immediately — only a
      # linking verb between them — so "Today the bins go out" is left alone
      # while "Your Today briefing went out" is not.
      BRIEFING_CLAIM_RX = /
        (?:\b(?:your|the)\s+)?
        (?:today(?:'s|’s)?(?:\s+briefing)?|briefing|rundown)\s*
        (?:is|was|has|just)?\s*(?:already\s+)?
        (?:ready|up(?:\s+now)?|out(?:\s+now)?|sent|posted|delivered|
           coming(?:\s+up)?|on\s+its\s+way|went\s+out|popped\s+in)
        \b[!.?]*\s*[✨💛💙🌟🎉]*\s*
      /xi

      # Below this, what survived the strip is a greeting and nothing else — so
      # the "briefing" was only ever the claim.
      MIN_BRIEFING_CHARS = 25

      def without_briefing_claim(body)
        return body unless today_briefing?

        stripped = body.to_s.gsub(BRIEFING_CLAIM_RX, "").squeeze(" ").strip
        return body if stripped == body.to_s.strip

        if stripped.length < MIN_BRIEFING_CHARS
          # Nothing was written. Report loudly rather than shipping either the
          # lie or an empty message — what's left is a bare hello, which is
          # useless but at least true.
          Buddy::Errors.report(
            section:   "turn.briefing_claim",
            exception: RuntimeError.new("Today briefing was only a claim that it had been sent"),
            user:      @user,
            extra:     { conversation_id: @conversation.id, body: body.to_s.truncate(200) },
          )
        end

        stripped
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] briefing claim strip failed: #{e.class}: #{e.message}")
        body
      end

      # Only on a briefing that was ORDERED to greet. Buddy::TodayBriefing
      # decides that from the thread, and when it decides not to, a reply with no
      # hello is exactly right — so this must never fire on that half.
      def greeting_missing?(body)
        return false unless today_briefing?
        return false if body.strip.empty?
        return false unless Buddy::TodayBriefing.greeting_ordered?(@inbound.body.to_s)

        !body.sub(LEADING_MOOD_RX, "").match?(GREETING_OPENER_RX)
      end

      # They are telling Buddy it didn't do the thing it said it did.
      #
      # Four times over two days, and the answer was written without looking
      # every time. Prod 3129 "Oh you didn't do anything" got "Ahh, nope, I
      # did." off nothing. Prod 3208 "That's not correct. That's the laundry
      # button being pressed" got "I've got a watch on the dryer stop call
      # already" when the watch really was on the button. Prod 3237 "You just
      # copied what you said before without actually running the task" was
      # right. Prod 3336 "I don't think you actually moved it to home. I think
      # that's a lie" was WRONG - the refile had happened - and Buddy agreed
      # anyway and invented a reason contradicting its own receipt.
      #
      # Note which way those cut: two arguments and two capitulations. The
      # error isn't a leaning, it's answering the question at all without the
      # one thing that settles it. Both `personality.rb` and the get_context
      # description already say to read `recent_actions` the moment this
      # happens; prod 3336 came a day after that instruction shipped. So the
      # check stops being something the model elects to do.
      #
      # Reads the REQUEST, like COMMAND_REQUEST_RX and for the same reason: the
      # reply can be worded any number of ways, but a person disputing an
      # action says so in a small handful of shapes.
      DISPUTED_ACTION_RX = /
          \byou\s+(?:didn(?:'|’)?t|did\s+not|never)\s+(?:actually\s+|really\s+|even\s+)?\w+
        | \bi\s+don(?:'|’)?t\s+think\s+you\s+(?:actually\s+|really\s+|ever\s+)?\w+
        | \b(?:that(?:'|’)?s|this\s+is|you(?:'|’)?re)\s+(?:a\s+)?(?:lie|lying|made\s+up)\b
        | \bnothing\s+(?:actually\s+)?(?:ran|happened|got\s+done)\b
        | \bdid\s+you\s+(?:actually|really|even)\b
        | \byou\s+just\s+(?:copied|repeated|re-?said)\b
        | \bwithout\s+(?:actually\s+)?(?:running|doing|calling|sending)\b
        # A correction arrives at the FRONT of the message or not at all, so
        # anchoring keeps this off an ordinary sentence that happens to contain
        # the words. Prod 3208 opens exactly this way.
        | \A\s*(?:no,?\s+|um,?\s+)?that(?:'|’)?s\s+not\s+(?:correct|right|true|what)\b
      /xi

      # Never on a self-initiated turn: nobody spoke, so there is no dispute to
      # answer. A turn that already read `recent_actions` has done the thing
      # this would ask for.
      def disputed_action?
        return false if self_initiated?
        return false if @read_actions

        @inbound.body.to_s.match?(DISPUTED_ACTION_RX)
      end

      CHECK_ACTIONS_NUDGE = <<~TXT.freeze
        STOP. They are disputing something you said you did, and you answered
        without looking it up. What you remember about this turn is the thing
        in question, so it cannot also be the evidence.

        Call `get_context` for `recent_actions` now, plus whichever section
        holds the thing itself - `active_watches`, `stashed_ideas`,
        `upcoming_reminders`, `running_timers`.

        Then answer from what you read, not from what you expect:
        - It IS there: say so plainly and name it, with the time it ran.
        - It ISN'T there: "You're right, that didn't go through" - then do it.
          One sentence. Never invent a reason why it didn't happen.

        Agreeing with them is not the safe default. They can be wrong about
        this, and conceding something that really did happen leaves them with a
        record they no longer trust and a correction you made up to explain it.
      TXT

      # The mirror of a disputed action: they aren't saying something DIDN'T
      # happen, they're saying something that DID happen shouldn't have.
      #
      # Prod 3484-3486. Suki learned two Afrikaans terms off Eve's example, an
      # undo row came back "Undone - unlearn lekker", and seventeen seconds
      # later Eve said "No, I didn't mean to undo that!". The answer was
      # "Nothing got undone on my side, so you're still good!" - and `lekker`
      # really was gone from the glossary. Nothing in DISPUTED_ACTION_RX covers
      # this shape, because none of it reads as a dispute: she was correcting
      # herself, not Buddy.
      #
      # The cost is the same either way. She was told a record exists that
      # doesn't, by the thing whose whole job is keeping it.
      UNDO_REGRET_RX = /
          \bdidn(?:'|’)?t\s+mean\s+to\s+(?:undo|remove|delete|cancel|unlearn|drop|forget)\b
        | \bdidn(?:'|’)?t\s+want\s+(?:you\s+)?to\s+(?:undo|remove|delete|cancel|unlearn|drop|forget)\b
        | \bwhy\s+did\s+you\s+(?:undo|remove|delete|cancel|unlearn|drop|forget)\b
        | \bundo\s+the\s+undo\b
        | \bput\s+(?:it|that|them|those)\s+back\b
        | \bi\s+still\s+want(?:ed)?\s+(?:it|that|them|those)\b
      /xi

      def undo_regret?
        return false if self_initiated?
        return false if @read_actions

        @inbound.body.to_s.match?(UNDO_REGRET_RX)
      end

      UNDO_REGRET_NUDGE = <<~TXT.freeze
        STOP. They are telling you that something you took away shouldn't have
        gone. That is a statement about YOUR record, and you answered it from
        memory - which is the one thing that can't settle it.

        Call `get_context` for `recent_actions` now. An undo leaves a receipt
        there like any other action, and it names what came off.

        Then, in the same reply:
        - It DID come off: say so plainly - "you're right, that one came off" -
          and PUT IT BACK with the tool that created it in the first place. You
          have the arguments; they're sitting in your own receipt. Don't ask
          whether they want it back. They just told you.
        - It didn't: say what the undo actually removed, so they can point at
          the right one.

        Never reassure them that nothing happened. "Nothing got undone on my
        side, so you're still good" was said over a glossary term that was
        already gone, and it left them believing they had something they don't.
      TXT

      # Asking to SEE what a camera has, as opposed to asking what happened.
      #
      # The line between the two is the whole of this arm, and it is not the
      # tense. "When was the last time somebody was at the door?" is a question
      # about a time, and answering it with the time of the last alert is
      # correct and wanted - no camera needs consulting to say when the doorbell
      # rang. What needs a camera is a request for the PICTURE: "show me the
      # last person that rang the doorbell" (prod 3789), "can you show me the
      # last person that came to the door" (3728), "show me the last person who
      # was at the door" (3751). All three got "I can't pull that up from here"
      # with `Camera Last Seen` sitting unused in the index, where it has never
      # run once since it was created.
      #
      # `who` counts as asking to see. Identifying a person is a question about
      # a face, and a face only comes off a frame - "who was at the door
      # yesterday morning" wants the picture even though it never says so.
      #
      # It reads the REQUEST rather than the reply because the reply gives
      # nothing away: a refusal is exempted from the false-claim guard on
      # purpose (DENIAL_RX - declining honestly is right when nothing ran), so
      # there is no arm below that can see this.
      #
      # Two rewrites of the task description were aimed here first, plus
      # `call_jil_function`'s own "never tell them you can't check something
      # that has a function for it". All landed, and 3790 broke the newest one
      # 26 minutes after it shipped. The description is not the lever.
      CAMERA_LOOK_RX = /
        (?=.*\b(?:camera|doorbell|door|driveway|backyard|porch)\b)
        (?:
            \bshow\s+(?:me|us)\b
          | \b(?:let\s+me|let\s+us|can\s+i|could\s+i|wanna|want\s+to|lemme)\s+see\b
          | \b(?:pull|bring)\s+up\b
          | \b(?:picture|photo|image|snapshot|screenshot|frame|footage|clip)\b
          | \bwho\s+(?:was|were|is|came|rang|showed|that)\b
        )
      /xi

      # The same nouns in a FORWARD-looking request are a watch, not a lookup -
      # "let me know the next time somebody comes to the door" (prod 3743) is
      # `remind_when` and gets the doorbell listener, which is a different tool
      # and a correct answer. Ordinarily the proposal it produces keeps this arm
      # from ever being reached; this is for the turn where the watch itself
      # failed to resolve, so the nudge doesn't send it after a camera instead.
      CAMERA_WATCH_RX = /
        \b(?:next\s+time|let\s+me\s+know|tell\s+me\s+when|ping\s+me|notify\s+me
           |remind\s+me|whenever|from\s+now\s+on|going\s+forward)\b
      /xi

      def camera_look_unanswered?
        return false if self_initiated?

        body = @inbound.body.to_s
        return false unless body.match?(CAMERA_LOOK_RX)
        return false if body.match?(CAMERA_WATCH_RX)

        camera_functions.any?
      end

      # The camera functions this person can actually call, by name.
      #
      # Looked up rather than assumed, because the nudge names them: pointing
      # someone at a tool that isn't in their index is telling them to invent a
      # name, which is the one thing `call_jil_function` warns hardest against.
      # An empty list means no camera is wired here and the refusal was honest.
      def camera_functions
        return @camera_functions if defined?(@camera_functions)

        @camera_functions = begin
          if defined?(Task)
            scope = @user.accessible_tasks.buddy_visible.functions
            # `uniq` because accessible_tasks LEFT JOINs shared_tasks and pluck
            # drops its DISTINCT, so a task both owned and shared comes back twice.
            scope.where("tasks.name ILIKE ?", "%camera%").limit(5).pluck(:name).uniq
          else
            []
          end
        rescue StandardError => e
          Rails.logger.warn("[Buddy::GPT::Turn] camera function lookup failed: #{e.class}: #{e.message}")
          []
        end
      end

      # Interpolated rather than frozen, because naming the functions is most of
      # the point - the failure is never that it lacked the instruction, it's
      # that it didn't connect the question to the entry in the index.
      def camera_nudge
        <<~TXT
          STOP. They asked to SEE something, and a camera is what shows it.

          #{camera_functions.map { |n| "`#{n}`" }.to_sentence} #{"is".pluralize(camera_functions.length)} in your `jil_functions` index right now. Call `call_jil_function` with `expect_result: true` and answer from what comes back.

          A camera holds what it already saw as well as what it can see now, and
          both are yours to pull. "Show me the last person that rang", "who was
          at the door yesterday morning" - these are asking for the FRAME, and
          the function that reads a past sighting takes the time they named.

          "Who" is a request to see. Recognising a person is a question about a
          face, and a face is only ever in a picture.

          Once you have the frame, describe what's actually in it. If the
          function comes back empty, say so plainly - "nothing since yesterday
          evening" is a real answer, and it's one you can only give after
          looking.
        TXT
      end

      # Worth a corrective round: nothing was proposed, we haven't already spent
      # the one retry we allow, and the reply either claims an action, points at
      # output that isn't there, waves off news nobody has heard yet, or opened a
      # briefing cold. Returns the nudge to send, or nil.
      def nudge_for(proposals, spoken, nudged, rounds)
        return nil if nudged || proposals.any?
        return nil if rounds >= MAX_ROUNDS || Time.current > @deadline
        return NOTIFY_NUDGE if self_initiated? && spoken.to_s.match?(DISMISSAL_RX)
        # Before the arms that read the reply. Those ask whether the words are
        # backed; this one asks whether the words were ever checked, and on a
        # disputed action that question comes first no matter how the reply is
        # phrased - a confident "I did" and a meek "you're right" are the same
        # failure when neither looked.
        return CHECK_ACTIONS_NUDGE if disputed_action?
        # Same footing and for the same reason: whether the record is right is
        # not a thing to answer off memory. Below the dispute arm only because
        # a message can be both, and "you didn't do that" is the older shape.
        return UNDO_REGRET_NUDGE if undo_regret?
        # Above the reply-reading arms, and for the same reason the two above it
        # are: whether it LOOKED comes before anything about how the answer is
        # worded. This one is invisible down there - the reply that goes out is
        # a refusal, and DENIAL_RX exempts those by design.
        return camera_nudge if camera_look_unanswered?
        return RETRY_NUDGE if unbacked_claim(spoken.to_s).present?
        # They asked for a thing to happen and nothing was called. Worth the
        # corrective round on its own — this is the half that gets the TV
        # actually turned off, rather than only stopping the lie about it.
        return RETRY_NUDGE if commanded_action_unanswered?(spoken.to_s)
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

      # Is this turn the Today briefing? Only that seed carries the marker (see
      # Buddy::TodayBriefing.deliver! and QuickActionsController#dispatch_trigger),
      # so an ordinary question about chores is untouched by it - ask "what
      # chores do I have" and you still get the whole list, because that time
      # you asked for it.
      def today_briefing?
        return false unless @inbound.metadata.is_a?(Hash)

        @inbound.metadata["buddy_action"].to_s == "today"
      end

      def tools
        @tools ||= [
          ContextTool.schema(user: @user, briefing: today_briefing?),
          PromptTool.schema,
          ImageTool.schema,
          ListenerTool.schema,
          *Buddy::SideEffects.function_schemas(theme: @conversation.buddy_theme),
          *Buddy::Tools.function_schemas(user: @user, briefing: today_briefing?),
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
        BuddyRelay.open_questions_for(@user, conversation: @conversation).count
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
            "kind"           => "buddy",
            "in_reply_to"    => @inbound.id,
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
        body = with_greeting(without_briefing_claim(display_body(apply_leading_mood(outcome[:text]))))
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
        settle_expression(acted: executed_anything?(result))
        broadcast(@reply.reload)
        ByteNotifier.notify(@user, @reply)
        queue_daily_audit
      end

      # The morning briefing is what the daily audit waits for: the report reads
      # best directly under it, one being what's coming and the other what broke.
      #
      # Hung off the turn FINISHING rather than polled for. A sweep asking every
      # few minutes whether the briefing had landed would spend all day answering
      # no, and the one moment it needs to know about is this one - the reply is
      # written, it's on screen, and nothing else is going to happen to it.
      def queue_daily_audit
        return unless @user.me?
        return unless scheduled_today?

        DailyAuditWorker.perform_async
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] daily audit enqueue failed: #{e.class}: #{e.message}")
      end

      # Was the seed behind this reply the SCHEDULED broadcast, as opposed to a
      # tap on the hero chip? Someone asking for a Today at four in the afternoon
      # is not the morning, and shouldn't drag a report along with it.
      def scheduled_today?
        meta = @inbound.metadata
        meta.is_a?(Hash) && meta["source"].to_s == "today_scheduled"
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
        # The EDIT shape. Everything above is a thing being added, set, logged,
        # run or taken away; none of it covers a thing being CHANGED, which is
        # what a correction always is. Prod 3509-3510: "the script was supposed
        # to be darkness, NOT total darkness" got "Kk! I fixed the script
        # wording to darkness." and buddy_routines 4 still read total_darkness,
        # with an updated_at identical to its created_at.
        #
        # First person and past tense, both load-bearing. "I've changed my mind"
        # survives (`my` isn't an object here), and so does "that changed
        # everything" - a bare verb is far too common to match on.
        | \bi\s+(?:just\s+)?(?:fixed|corrected|changed|updated|swapped|edited|reworded|renamed)\s+
            (?:it|that|the|your|both)\b
        | \bi(?:'|’)ve\s+(?:just\s+)?(?:fixed|corrected|changed|updated|swapped|edited|reworded|renamed)\s+
            (?:it|that|the|your|both)\b
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
        # The PICTURE shape. Prod 3739-3742: "Show me the doorbell" got "Posted
        # a live doorbell frame." with no call of any kind — the wording lifted
        # from an earlier turn that HAD run, sitting in history. The person had
        # to say "You did not do that" to find out.
        #
        # A picture is the one claim nobody can verify by looking, because the
        # absence of an image reads as an image that hasn't loaded yet.
        #
        # Anchored on the NOUN rather than the verb: "sent" and "posted" are
        # everywhere ("I sent that to Chelsea", "posted on the fridge"), but a
        # delivery verb landing on a picture noun within a few words is only
        # ever this claim. Up to three words between them covers "a live
        # doorbell frame" and "the backyard camera picture".
        # (No slashes in these comments - see the note above.)
        | \b(?:posted|sent|shared|dropped|pulled\s+up|grabbed)\s+
            (?:you\s+)?(?:a|an|the|your|it|that|another)\s+
            (?:[\w-]+\s+){0,3}
            (?:frames?|photos?|pictures?|images?|snapshots?|shots?)\b
        | \b(?:frame|photo|picture|image|snapshot)\s+(?:is\s+)?
            (?:in|on)\s+(?:the\s+)?(?:thread|chat)\b
        # The CANCELLATION shape, from prod 3171. "I don't need to water the
        # front flower bed" got "I pulled the front flower bed reminder down so
        # it won't keep bugging you!" over a cancel_reminder that was only ever
        # PROPOSED. She read it as handled, never tapped, and the reminder went
        # off again at 8am the next morning and every morning after.
        #
        # Every alternative above is about a thing being added, set, logged or
        # run. Not one of them covers a thing being taken AWAY, which is half of
        # what gets asked for and the half nobody notices has failed - an
        # unwanted reminder that keeps arriving reads as the system working.
        #
        # Past tense only, and each one needs an object. "want me to remove
        # that?" and "I can cancel it" are offers and must survive.
        | \b(?:cancell?ed|removed|deleted|unscheduled)\s+(?:it|that|those|them|the|your|this)\b
        # "pulled the reminder down", "took it off". The particle is what makes
        # it a removal - a bare "pulled up your calendar" is not a claim of one.
        #
        # Split in two because `the` plus an arbitrary noun is where this bites:
        # "Eve took the puppy out" is an ordinary sentence and the first draft
        # retracted it. A pronoun can be trusted with the particle alone; a noun
        # has to be one of the things that actually gets scheduled.
        | \b(?:pulled|took)\s+(?:it|that|this|those|them)\s+(?:down|off)\b
        | \b(?:pulled|took)\s+(?:the|your)[^.!?\n]{0,40}?
            \b(?:reminder|alarm|timer|watch|event|chore|item|task|notification)s?\s+(?:down|off)\b
        | \b(?:it|that)(?:'|’)?s\s+(?:cancell?ed|removed|deleted|off\s+the\s+list)\b
        # The reassurance that comes WITH a cancellation and says the same thing.
        # `remind` is deliberately absent: "I won't remind you unless you ask" is
        # an honest description of what it does, not a claim to have stopped.
        | \bwon(?:'|’)?t\s+(?:keep\s+)?(?:bug|bugg?ing|bother(?:ing)?|nag(?:ging)?|pester(?:ing)?)\s+you\b
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

      # ---- the claim the reply's own words can't give away --------------------
      #
      # Everything above reads the REPLY, which is deliberate and usually right.
      # It cannot settle the plainest device answer there is. Prod 3229: "Turn
      # the tv off" was answered "Kk! TV's off." with no tool call and nothing
      # run, and no rule here fires on it — because that exact sentence is also
      # the correct answer to "is the TV on?", where nothing SHOULD have run.
      # The claim arm above dodges the ambiguity by demanding a trailing "now" or
      # "low" ("the fan is on low now"), so the bare form walks straight past.
      #
      # The words can't tell those two apart. What the person ASKED for can, and
      # it's sitting right there: an imperative orders a thing to happen, and a
      # question doesn't. So this arm reads the REQUEST, and only then asks
      # whether the reply behaved like one that did it.
      #
      # The verb list is the part that has to keep earning its place. It started
      # as house-device vocabulary, and prod 3236 walked past it: "print again"
      # got "Yessss, the printer's running the last file again." off a single
      # call with nothing run — the THIRD time that same request has been
      # answered with a fabricated receipt (prod 2054 is the other two). Each of
      # the earlier rounds patched the claim regex below instead, and each time
      # the next occurrence dodged it by naming a different noun ("it's running"
      # → "the printer's running"). The request side can't be dodged that way:
      # "print again" is an imperative no matter how the reply is worded.
      #
      # So the verbs here are the ones that ONLY read as orders in this app,
      # each tied to a real tool. Anything with an everyday non-command sense
      # ("tell me...", "save it for later") stays out — a false positive here
      # rewrites a good reply, which is worse than a missed catch.
      COMMAND_REQUEST_RX = /
        \A\s*(?:hey[\s,]+\w+[\s,]+)?
        (?:(?:please|can\s+you|could\s+you|would\s+you|go\s+ahead\s+and|go|just)\s+)*
        (?:turn|switch|toggle|set|start|stop|shut|open|close|lock|unlock|play|pause|
           resume|dim|brighten|run|fire|launch|restart|reboot|enable|disable|mute|unmute|
           print|reprint|queue|preheat|cancel|remind|schedule|undo)
        # An object, not a preposition. "start with the milk" and "run by me
        # first" open with a command verb and are conversation, so the thing
        # right after the verb is what separates an order from a turn of phrase.
        \b(?!\s+(?:with|by|from|about)\b)
      /xi

      # ---- a command that said WHEN ------------------------------------------
      #
      # Prod 3562, 10:44 AM: "Play Whisper Nap sound at 11." Buddy answered
      # "Playing the nap sound on Whisper." and called `call_jil_function` on
      # the spot. The sound went off in the room, 16 minutes early, next to a
      # sleeping dog.
      #
      # This is the same failure `message_partner` carries a whole section
      # about ("A DELAY IS IN THE INSTRUCTION, NEVER IN THE NOTE") and prose
      # didn't hold, for the reason prose never holds here: the tool that acts
      # NOW is right there, its description says nothing about time, and every
      # example in it is immediate. The difference is that a relay sent early is
      # embarrassing and a sound played early is physical.
      #
      # So the request decides, not the reply. A person who says when is
      # unambiguous, and unlike the reply there is only a small handful of ways
      # to say it.
      #
      # Every alternative needs a real clock or a real deferral word. `at 72`
      # (a thermostat) and `at 50` (a dimmer) must not read as times, so a bare
      # hour is capped at 12 and anything longer needs a colon or a meridiem.
      DEFERRED_COMMAND_RX = /
          \bat\s+(?:1[0-2]|[1-9])\s*(?:am|pm|o'?clock)\b
        | \bat\s+\d{1,2}:\d{2}\s*(?:am|pm)?\b
        | \bat\s+(?:1[0-2]|[1-9])\b(?!\s*(?:%|percent|degrees?))
        | \bat\s+(?:noon|midnight)\b
        | \bin\s+(?:an?|\d+)\s+(?:sec|second|min|minute|hour|hr)s?\b
        | \b(?:tonight|tomorrow|later\s+today|in\s+the\s+morning)\b
        | \bthis\s+(?:morning|afternoon|evening)\b
        | \bbefore\s+(?:bed|bedtime|dinner|lunch|work)\b
        | \bwhen\s+i\s+(?:get\s+(?:home|back|up)|wake\s+up)\b
      /xi

      # The other half of an imperative, for the writes the verb list above
      # doesn't reach. COMMAND_REQUEST_RX is device vocabulary and it also arms
      # `retract_false_claim!`, where a false positive REWRITES a good reply —
      # so verbs that only matter to this gate get their own list rather than
      # being pushed into that one, where being wrong costs more.
      #
      # Prod 3897 is why it exists: "Add "something" to my todo list in 2
      # minutes" never reached the gate at all, because "add" is not a device
      # verb and never will be.
      WRITE_REQUEST_RX = /
        \A\s*(?:hey[\s,]+\w+[\s,]+)?
        (?:(?:please|can\s+you|could\s+you|would\s+you|go\s+ahead\s+and|go|just)\s+)*
        (?:add|put|remove|delete)
        # Same guard as above: the word after the verb is what separates an
        # order from a turn of phrase.
        \b(?!\s+(?:with|by|from|about)\b)
      /xi

      # The tools that mean LATER. One of these landing in the same turn says the
      # model understood the time, and nothing here should get in its way.
      SCHEDULING_TOOLS = %i[
        schedule_reminder schedule_trigger schedule_function alarm set_timer remind_when move_reminder
      ].freeze

      # Does this call actually put something on the clock? `set_timer` is the
      # one that has to be read rather than just named, because a BARE countdown
      # defers nothing. Prod 3897's second shape is the add plus a plain timer:
      # the timer IS the artifact of the mistake, and letting it stand in for
      # "the model understood the time" is what lets the write through. Only a
      # wait carrying the rest of the sequence counts.
      def self.defers?(name, arguments)
        name = name.to_sym
        return false unless SCHEDULING_TOOLS.include?(name)
        return true unless name == :set_timer

        args = arguments || {}
        wait = args[Buddy::Tools::WAIT_ARG.to_s].presence || args[Buddy::Tools::WAIT_ARG]
        ActiveModel::Type::Boolean.new.cast(wait)
      end

      # Told the way every other refusal is told, because it IS one: the call did
      # not happen. `failed` is load-bearing rather than cosmetic — it drops the
      # call from `proposals`, and it arms `retract_false_claim!` so a reply that
      # says the sound is playing gets taken down instead of being believed.
      def self.held_for_later(name)
        {
          status: "failed",
          error:  "#{name} does it NOW, and they said when",
          note:   "This did NOT run, on purpose. A time in the request says when to act; " \
                  "it is never part of what to do. Put it on the clock instead: " \
                  "`schedule_function` is this exact call with a time on it, `schedule_trigger` " \
                  "for a Jil listener scope, `schedule_reminder` with `text: \"run <name>\"` for " \
                  "a saved routine, `alarm` when it has to interrupt them, `set_timer` for a " \
                  "countdown. Never do it now as a consolation, and never say it's scheduled " \
                  "when it isn't.",
        }
      end

      # Did they order something done AND say when? Both halves required: "at
      # 11" on its own is conversation, and "play the nap sound" on its own is
      # exactly what these tools are for.
      def deferred_command?
        return false if self_initiated?

        body = @inbound.body.to_s
        return false unless body.match?(COMMAND_REQUEST_RX) || body.match?(WRITE_REQUEST_RX)

        body.match?(DEFERRED_COMMAND_RX)
      end

      # A reply that DECLINES is honest and must survive. "I can't reach the TV
      # from here" is the right answer when nothing ran, and retracting it would
      # replace a real answer with a shrug.
      DENIAL_RX = /
        \b(?:can(?:'|’)?t|cannot|couldn(?:'|’)?t|won(?:'|’)?t|unable|no\s+way\s+to)\b
        | \b(?:don(?:'|’)?t|do\s+not|didn(?:'|’)?t)\s+(?:have|see|find)\b
        | \b(?:isn(?:'|’)?t|not)\s+(?:wired|set\s+up|hooked|connected|available)\b
      /xi

      # Byte's own sound effect for having just flipped something physical. In
      # every one of the 18 times it has appeared in prod it sat on a claim
      # about a device — lights, monitors, blinds, the printer — and never on
      # ordinary conversation. It is the one completion marker the persona OWNS
      # rather than one a regex has to guess at, so it can't be dodged by
      # renaming the noun, which is how the claim regex keeps getting walked
      # past. Prod 3128 is what it catches: "Good night" is not an imperative
      # and has no verb to match, but it got "Total darkness, and the monitors
      # are out. *click* 💙" off a single call with nothing run.
      CLICK_RX = /\*click\*/i

      # It belongs HERE and not in COMPLETION_CLAIM_RX because the same sentence
      # is the right answer to "did you turn the lights off?" — reporting a
      # state Buddy set earlier, with correctly nothing running this turn.
      # Asking is the whole difference, and unlike the reply, the question is
      # unambiguous.
      QUESTION_RX = /
        \?
        | \A\s*(?:is|are|was|were|did|do|does|can|could|will|would|has|have|had|
                  how|what|when|where|why|which|who)\b
      /xi

      # Did they order something done, and did the reply act like it happened?
      #
      # Two ways in. Either the REQUEST was an imperative, or the reply carries
      # Buddy's own tell for having done a physical thing and the request wasn't
      # a question. Whether anything actually RAN is the caller's half, and it's
      # the same three-part test the reply-text guard uses. A reply that asks a
      # question back or says it can't is doing the right thing with a command
      # it couldn't carry out.
      def commanded_action_unanswered?(body)
        return false if self_initiated?
        return false if body.to_s.strip.empty?
        return false if body.match?(SOLICITS_INFO_RX) || body.match?(DENIAL_RX)
        return true if @inbound.body.to_s.match?(COMMAND_REQUEST_RX)

        body.match?(CLICK_RX) && !@inbound.body.to_s.match?(QUESTION_RX)
      end

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
      # The reply asserts completion AND nothing executed. What a pending row
      # changes is the CORRECTION, not whether one is needed.
      #
      # This used to bail out entirely on a pending row, reasoning that a
      # checkbox is visible on its own so a wrong tense above it is only a tone
      # bug. Prod 3171 is what that costs: "I pulled the front flower bed
      # reminder down so it won't keep bugging you!" sat above an untapped
      # cancel_reminder. A checkbox is only visible to someone still looking for
      # one, and a sentence saying the thing is already handled is precisely the
      # instruction to stop looking. She didn't tap it, and it fired again the
      # next morning.
      #
      # So a pending row earns PENDING_BODY instead of an exemption. The
      # :commanded arm is the one that still steps aside for it: that arm infers
      # a failure from the REQUEST being an imperative, and a proposal waiting on
      # screen is an answer to one, so "here's that ready to go" must survive.
      def retract_false_claim!(result)
        body    = @reply.body.to_s
        pending = pending_rows?(result)
        kind    = unbacked_claim(body) || (:commanded if !pending && commanded_action_unanswered?(body))
        return if kind.nil?
        return if executed_anything?(result)
        # Everything below assumes the claim is about THIS turn, which is why
        # "nothing executed" reads as "nothing happened". A turn that fetched
        # `recent_actions` is answering from the record instead, and the true
        # answer to "did you do that?" is frequently a completion sentence about
        # an EARLIER turn: "yep, logged it at 6:03." Same carve-out QUESTION_RX
        # makes for "did you turn the lights off?", extended to the case where
        # Buddy went and looked rather than being asked outright — which
        # CHECK_ACTIONS_NUDGE now pushes it into on every disputed action.
        return if @read_actions

        Rails.logger.warn(
          "[Buddy::GPT::Turn] retracted unbacked #{kind}#{" over a pending row" if pending} " \
          "on message=#{@reply.id} user=#{@user.id}: #{body.truncate(160).inspect}",
        )
        @reply.update!(
          body:     retraction_body(kind, pending),
          metadata: (@reply.metadata || {}).merge("retracted_claim" => true),
        )
      end

      def retraction_body(kind, pending)
        return PENDING_BODY if pending
        return UNDONE_BODY if kind == :commanded

        FALLBACK_BODY
      end

      # Something genuinely ran: an acting answering tool settled inside the
      # turn, a level-1 tool fired, or a level-2 row came back executed. A
      # "failed" or "partial" row explicitly does NOT count.
      def executed_anything?(result)
        return true if @acted
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
      #
      # `acted` is a turn that DID something. React first: a pet still resting
      # on neutral after doing something for someone is the flat-faced machine
      # the persona's face rules are trying to avoid. react! leaves a mood the
      # model chose alone, so this only fills a silence.
      def settle_expression(acted: false)
        Buddy::ExpressionState.react!(@conversation) if acted
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
        stray.each { |kind, rx| Rails.logger.warn("[Buddy::GPT::Turn] stray #{kind} in output: #{raw[rx]}") }

        cleaned = stray.each_value.reduce(raw) { |body, rx| body.gsub(rx, "") }
        dedupe_paragraphs(cleaned.gsub(/\n{3,}/, "\n\n").strip)
      end

      # Drop a paragraph that repeats one already said.
      #
      # Buddy::GPT::Client does this too, across the message parts of a response
      # — but it compares them BEFORE the markers come off, and a response whose
      # parts differ only by a `[[mood:...]]` prefix therefore isn't caught.
      # Prod 3229: "Turn the tv off" came back as "Kk! TV's off." twice, the two
      # parts identical except that the first carried a mood marker that is
      # stripped four lines above this. Once it's gone they're the same sentence,
      # and the person reads it, reads it again, and learns nothing the second
      # time.
      #
      # So the check belongs HERE as well, after every normalization, which is
      # also the last point before the body is broadcast. A single part that
      # simply repeats itself is caught by the same pass.
      #
      # Exact match is not enough on its own. Prod 3337 came back as the same
      # retraction twice, reworded in the middle: "it's still sitting in home
      # already, so there wasn't anything to move" and "it's already in home,
      # so there wasn't anything to move", opening and closing identically. To
      # a reader that is one sentence said twice; to `==` it is two sentences.
      # A model redrafting mid-response produces exactly this shape.
      def dedupe_paragraphs(body)
        kept = []
        body.split(/\n{2,}/).filter_map { |para|
          para = para.strip
          next nil if para.empty?
          next nil if kept.any? { |seen| restatement?(seen, para) }

          kept << para
          para
        }.join("\n\n")
      end

      # Two paragraphs saying the same thing. Word-level Sørensen–Dice over the
      # bare words, so punctuation, casing and a few swapped words don't hide a
      # repeat.
      #
      # The threshold is deliberately high and the floor deliberately exists:
      # short replies ARE mostly stock phrases, and "Okie!" against "Ok!" or
      # "Done." against "Done!" must stay two separate things whenever Buddy
      # genuinely meant both. Below eight words this stays out of the way and
      # exact match (which already ran) does the work.
      SIMILAR_ENOUGH = 0.8
      MIN_COMPARABLE = 8

      # Containment is the hole under the floor. Prod 3575: "Sure thing, what
      # time later?" followed by "What time later?" — five words and three, so
      # Dice never ran, and the two aren't identical. A LATER paragraph whose
      # words appear as a contiguous run inside an EARLIER one adds nothing the
      # earlier one didn't already say. Directional on purpose: the other way
      # round ("Water the plants" then "Water the plants at 5") is the second
      # paragraph adding to the first, and both belong.
      MIN_CONTAINED = 3

      def restatement?(a, b)
        return true if a.casecmp?(b)

        left, right = words_of(a), words_of(b)
        return true if contained?(left, right)
        return false if left.size < MIN_COMPARABLE || right.size < MIN_COMPARABLE

        overlap = left.tally.sum { |word, n| [n, right.count(word)].min }
        (2.0 * overlap / (left.size + right.size)) >= SIMILAR_ENOUGH
      end

      # Is `later` a contiguous run of words inside `earlier`? Floored so
      # "Okie!" against "Ok!" — the pair the size guard exists to protect —
      # stays two separate things.
      def contained?(earlier, later)
        return false if later.size < MIN_CONTAINED || later.size > earlier.size

        earlier.each_cons(later.size).any? { |run| run == later }
      end

      def words_of(para)
        para.downcase.scan(/[\p{L}\p{N}']+/)
      end

      # ---- progress ----------------------------------------------------------

      # One line per tool call, pushed to the bubble as it happens.
      #
      # Deliberately NOT persisted. These describe a turn in flight and mean
      # nothing once it lands, so they ride on the broadcast only: the reply row
      # never holds them, finalize has nothing to clear, and a reload mid-turn
      # simply shows the placeholder it always did.
      def note_progress(name, args=nil)
        @steps ||= []
        phrase = Buddy::Progress.phrase_for(name, args)
        return if phrase.nil?
        # A round that repeats a call (the model restating itself) would
        # otherwise stutter the same line twice.
        return if @steps.last == phrase

        @steps << phrase
        broadcast(@reply, steps: @steps)
      end

      def broadcast(message, steps: nil)
        wire = message.as_wire
        wire = wire.merge(metadata: (wire[:metadata] || {}).merge("steps" => steps)) if steps.present?
        MonitorChannel.broadcast_to(@user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: wire },
        })
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] broadcast failed: #{e.class}: #{e.message}")
      end
    end
  end
end
