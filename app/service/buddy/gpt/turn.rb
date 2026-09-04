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
      # The em dash rule is written down four times - in the persona, twice in
      # byte.md, and once per other tone profile - and em dashes still come
      # out. Four statements of a rule is the point at which a fifth stops
      # being the fix: this is a shape, not a judgement, so it's normalized on
      # the way out instead of asked for.
      #
      # An em dash between words becomes " - " (what every profile asks for);
      # one already sitting in spaces just loses the character, so " — " can't
      # turn into "  -  ".
      #
      # Public because the eval harness applies it too — it doesn't go through
      # display_body, and a harness that flags what production quietly fixes
      # reports a problem nobody has.
      def self.normalize_dashes(body)
        body.to_s.gsub(/\s*[—–]\s*/, " - ")
      end

      # An offer to write something down, with nothing written down.
      #
      # `request_feature` exists so that "I can't do that one" is never the
      # whole answer, and its own description says calling it IS the offer. It
      # still came back as prose across three eval runs - "I can't place the
      # order from here, but I can jot down what kind you're craving" - with no
      # call under it, which leaves the person to ask a second time for a thing
      # they already asked for.
      #
      # Only the OFFER shape, never a plain refusal: "I can't find a car wash
      # logged yesterday" promises nothing and needs no round.
      OFFER_TO_NOTE_RX = /
        \b(?: i\s+can | i\s+could | want\s+me\s+to | shall\s+i | happy\s+to |
              if\s+you\s+(?:want|like),?\s+i\s+(?:can|could) )\b
        [^.!?\n]{0,70}
        (?:
          \b(?:put|pop|add|stick|get)\b [^.!?\n]{0,40} \b(?:list|wish\s*list|queue)\b
          |
          \b(?:jot|write|note|scribble)\b [^.!?\n]{0,20} \bdown\b
          |
          \b(?:note|write)\s+(?:it|that|this)\b
        )
      /xi

      def self.unfiled_offer?(body)
        body.to_s.match?(OFFER_TO_NOTE_RX)
      end

      # THE backstop, and the reason the list above stopped growing.
      #
      # Every alternative in COMPLETION_CLAIM_RX is a PHRASING, and there is
      # always one more phrasing. "I marked `Make Meal` off" walked past it
      # because the record was named instead of pronouned. "Posted a live
      # doorbell frame" walked past it because the verb was a delivery verb.
      # "Kk! I added those three to **Before Bed**" (prod 4745) walked past
      # `added (it|that|them) to` because THREE ITEMS ARE NOT "IT". Each one got
      # its own alternative afterwards, each one shipped, and the next sentence
      # was already on its way. He is right that this is ridiculous.
      #
      # What makes the list necessary at all is that it runs on every reply,
      # including turns where plenty ran and only the claimed part didn't - and
      # there, a broad rule would retract honest replies constantly.
      #
      # This one is not for those turns. It is only ever consulted once the
      # machinery has already established that **NOTHING EXECUTED, NOTHING IS
      # PENDING, AND NOTHING WAS PROPOSED** - a turn on which Buddy did not
      # touch the world at all. On that turn there is no true sentence in the
      # first person past tense about having done something, so this doesn't
      # have to guess which words the model chose. It only has to notice that
      # the reply is written in the voice of having acted.
      #
      # Which is why it's a verb list rather than a shape list: the shapes are
      # unbounded, the verbs are not.
      SILENT_TURN_CLAIM_RX = /
        \bi(?:(?:'|\u2019)ve)?\s+
          (?:just\s+|already\s+|now\s+|gone\s+ahead\s+and\s+)?
          (?:added|set|made|created|put|logged|saved|scheduled|started|sent|
             moved|removed|deleted|cancell?ed|canceled|updated|changed|fixed|
             marked|filed|stashed|booked|queued|renamed|swapped|turned|
             switched|dropped|popped|slotted|stuck|noted)
          # Not a verb of INTENDING, of LOOKING, or of having a thought. "I
          # started to look", "I made sure", "I set out to" and "I've changed my
          # mind" are all silent-turn-legal sentences, and the last of those is
          # in the turn spec precisely because a bare verb match eats it.
          \b(?!\s+(?:to|sure|out|my\s+mind)\b)
        # The passive half, which is the same claim with Buddy taken out of it.
        # "They're added", "that's on the list", "those are set" - all of them
        # report a record that does not exist, in a voice that never says "I".
        | \b(?:they|those|these|it|that|both|all\s+\w+)
            (?:(?:'|\u2019)re|(?:'|\u2019)s|\s+are|\s+is)\s+
            (?:(?:now|all)\s+)?
            (?:added|set|logged|saved|scheduled|done|in\s+there|
               on\s+(?:the|your)\s+\w+)\b
      /xi

      # A reply on a turn that touched nothing, written as though it had.
      #
      # Deliberately NOT part of `unbacked_claim`: that one is asked on every
      # turn and has to survive the ones where something really did run. This is
      # only asked behind the "nothing executed" gate, and its whole value is
      # being broad enough that a new phrasing doesn't need a new release.
      def self.silent_turn_claim?(body)
        return false if body.blank?
        # An honest refusal and an honest question both survive, for the same
        # reasons they survive everywhere else in here.
        return false if body.match?(DENIAL_RX)

        body.match?(SILENT_TURN_CLAIM_RX)
      end

      def self.unbacked_claim(body)
        return nil if body.blank?
        return :call if body.match?(TRIED_CLAIM_RX)
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
      # A resolve that found several records and no way to choose. The
      # candidates go up as buttons and a tap runs the original call, so the
      # question is answered without the person typing a name back and without
      # a second model turn to read it. Falls through to the plain sentence
      # when there is nowhere to put buttons - a routine, an eval sweep.
      rescue Buddy::Ambiguous => e
        asked = Buddy::Disambiguation.ask!(
          user: user, conversation: conversation, tool: tool, payload: payload, error: e,
        )
        failure = resolve_failure(asked ? Buddy::Disambiguation::ASKED_NOTE : e.message)
        # Read and removed by tool_output before the hash goes to the model:
        # it's for `start_over?`, which must not re-run a turn whose question is
        # already sitting in front of them.
        failure[:asked_choice] = true if asked
        [failure, nil, nil]
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
      #
      # **It must not describe the reply it is replacing.** The draft is never
      # delivered - the bubble holds PLACEHOLDER until the finished body is
      # written once, and the retraction IS that one write - so "I said that
      # like it was done" apologises for a sentence nobody has read. Rocco, on
      # prod 5333: *"The user never saw that message, so that's just
      # annoying/confusing."* Say what is true about the WORLD (it didn't
      # happen), never about the draft.
      #
      # And it no longer asks. "Want me to have another go at it?" is a request
      # for permission to do the thing already asked for, and the "Yes" under it
      # worked first time - which is what start_over? now does instead, before
      # any of this is reached.
      UNDONE_BODY = "That didn't go through - nothing actually ran on my end. Give me another " \
                    "angle on it and I'll keep at it.".freeze

      # What to say when the row is REAL and only the tense was wrong.
      #
      # Distinct from UNDONE_BODY on purpose: nothing was fabricated here, the
      # thing is built and sitting on screen waiting to be tapped, so throwing
      # the reply away would be as wrong as leaving the claim standing.
      PENDING_BODY = "Almost - I've got that ready right below, it just needs your tap.".freeze

      # What to say when NOTHING ran and the reply spoke as though something had.
      #
      # Distinct from UNDONE_BODY, which infers the failure from the request
      # being an imperative and so can afford to be tentative about it. This one
      # is read off the turn's own machinery - no tool executed, nothing is
      # waiting on a tap - so the record is not in doubt and the sentence
      # shouldn't sound like it is. Say what the receipts hold, which is
      # nothing.
      #
      # Same rule as UNDONE_BODY about not describing the draft, and for the
      # same reason. "Let me actually do it" went with it: by the time this is
      # reached, start_over? has already been and gone, so it was a promise the
      # turn had no round left to keep.
      SILENT_BODY = "This one hasn't actually happened - nothing ran, so there's no receipt for " \
                    "it. I don't want you thinking it's done.".freeze

      # What to say when the claim was about the CALL rather than a record.
      # "I did try now" and "the snapshot call came back clean" are not a wrong
      # tense over a real row - there is nothing under them at all - and the
      # person is mid-argument about whether it happened by the time one lands.
      # Saying which way it actually went is the only useful thing left.
      NO_CALL_BODY = "Actually, no - I didn't run anything just then, so I've got nothing to " \
                     "report back on it.".freeze

      # What to APPEND when a turn did the work and then said it hadn't.
      #
      # Prod 4661, 25 Aug: three inventory edits, all executed, under "I didn't
      # actually get the merge done cleanly, and I'm not going to pretend I
      # did." He was left believing a correct inventory was broken, and the
      # remedy offered underneath would have re-merged two rows that no longer
      # existed. The mirror of a false claim and the more expensive one, because
      # nothing about it looks like a failure - it looks like honesty.
      #
      # Appended rather than swapped in: the reply may be right about everything
      # else in it, and the correction is one fact it got wrong.
      DENIAL_CORRECTION = "(Correction from me: that did go through - %s.)".freeze

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

      # The third of the same family, and the one that cost a typed instruction.
      #
      # Buddy::GPT::History#form_standin represents a past form card to the model
      # as `[form you put up: ... - answered]`. Prod 4202: "Log 4 more Build
      # Furniture for the Wayfair Desk" came back with that marker as the ENTIRE
      # reply body - two model calls, no tool call, and the instruction dropped.
      # It took two more messages to get the four completions written.
      FORM_FRAMING_RX = /\[form you put up:[^\]\n]*\]/i

      # What the provider said is not something to say back.
      #
      # A failed turn posted the exception verbatim, which is how "You have no
      # credits remaining. Add credits to continue using the API at
      # https://platform.openai.com/settings/organization/billing/" arrived in
      # the thread as Buddy's reply, billing link and all (prod 4185, and 2240
      # before it). The person can't act on any of it, half of it isn't theirs
      # to read, and it doesn't sound like anyone. That one fixed itself when
      # the auto-recharge landed three minutes later.
      #
      # The raw text still goes to the log and onto the row's metadata, so it's
      # there for whoever looks into it - it just stops being the reply.
      FAILURE_BODY = "Something went wrong on my end and that one didn't make it out. Give me another go?".freeze

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
        outcome[:ok] ? finalize_success(outcome) : finalize_failure(outcome[:error], kind: outcome[:error_kind])
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

      # Two attempts, and the second one starts CLEAN. See start_over?.
      #
      # One deadline across both: TURN_BUDGET_SECONDS is how long the person is
      # willing to watch a pulsing bubble, and that doesn't double because the
      # first attempt went nowhere.
      def converse
        @deadline = Time.current + TURN_BUDGET_SECONDS
        attempt   = 0
        outcome   = nil

        loop do
          previous = (outcome if attempt.positive?)
          attempt += 1
          outcome  = attempt_turn(previous: previous)
          break unless outcome[:ok]
          break unless start_over?(outcome, attempt)

          Rails.logger.warn(
            "[Buddy::GPT::Turn] nothing landed on attempt #{attempt} for message=#{@inbound.id} " \
            "user=#{@user.id}: #{outcome[:text].to_s.truncate(160).inspect} - going again",
          )
        end

        outcome
      end

      # Go again from a clean slate rather than telling them it didn't happen
      # and asking whether to try.
      #
      # **The person's own "yes, try again" has always worked where the in-turn
      # corrective round didn't, and the words are not the difference.** A
      # nudge APPENDS to the input, so the model rereads its own failed call and
      # the error under it and reasons on from there; the retry they type starts
      # a new turn, where History.build rebuilds the thread from the message
      # rows and none of that wreckage is in front of it. Prod 5333: "Move the
      # plunge with Wil to the 14th" ended "Nothing actually ran. Want me to
      # have another go at it?", and the "Yes" underneath it moved the event on
      # the first try. Asking a person to type that is asking them to do
      # something we can do.
      #
      # Only ever on a turn that is ALREADY lost - nothing ran, nothing is
      # waiting on a tap, and the reply is about to be retracted - so the worst
      # case is a second attempt at words that were going to be thrown away.
      #
      # `@read_actions` stands it down for the same reason the retraction does:
      # a turn that went and read the action log is answering about an EARLIER
      # one, and "logged it at 6:03" is then true.
      def start_over?(outcome, attempt)
        return false if attempt > 1
        return false if @acted || @asked_choice || @read_actions
        return false if outcome[:proposals].any?
        return false if Time.current > @deadline

        body = outcome[:text].to_s
        unbacked_claim(body).present? ||
          self.class.silent_turn_claim?(body) ||
          commanded_action_unanswered?(body)
      end

      # What the second attempt is told. The draft rides along through
      # `draft_item`, which already says it was never sent and that whatever
      # comes next replaces it.
      SECOND_ATTEMPT_NUDGE = <<~TXT.freeze
        That attempt is finished and NOTHING ran: no tool call landed, so there
        is no record of it and nothing for them to tap. This is a fresh start on
        the same message, and the calls that went wrong are deliberately not in
        front of you any more.

        Do the thing they asked for. Call the tool. If you need a record's real
        name or the date it's actually on, look it up first rather than guessing
        at arguments - a guessed argument is the usual reason the first attempt
        found nothing.

        If it genuinely can't be done, say what stopped you and what you'd need.
        Say it as a plain answer: they have not seen a word of the last attempt,
        so an apology for it reads as an apology for nothing.
      TXT

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
      def attempt_turn(previous: nil)
        input     = History.build(@conversation, upto: @inbound)
        input    += [{ role: :developer, content: routine_directive }] if routine_directive
        if previous
          input += draft_item(previous[:text]) + [{ role: :developer, content: SECOND_ATTEMPT_NUDGE }]
        end
        # Seeded with the words the last attempt ended on, under the same rule
        # that governs rounds: the LAST thing said wins, and a round that says
        # nothing doesn't get to be it. Without this, a second attempt that came
        # back silent left the turn with no text at all - so a claim it was
        # started over to correct went out as a blank-reply fallback instead of
        # being retracted.
        spoken    = previous&.dig(:text).presence
        proposals = []
        rounds    = 0
        @failed   = Set.new
        @seen     = Set.new
        @acted    = false
        # Whether a resolve found several records and put the choice up as
        # buttons. Nothing ran and nothing is proposed on such a turn, which
        # looks exactly like a lost one - but the question IS on screen and
        # going again would post it twice. See start_over?.
        @asked_choice = false
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
        # ...and separately, whether a wait was opened for the rest to queue
        # behind. Not the same thing, and see scheduled_for? for why.
        @queued        = false
        nudged         = false

        loop do
          rounds += 1
          result = run_round(input)
          # Record usage BEFORE the ok check: a failed or truncated response still
          # consumed tokens and still bills.
          record_usage(result)
          return { ok: false, error: result[:error], error_kind: result[:error_kind] } unless result[:ok]

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
            input += draft_item(round_text) + [{ role: :developer, content: nudge }]
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
          @scheduled ||= calls.any? { |c| self.class.puts_on_clock?(c[:name], c[:arguments]) }
          @queued    ||= calls.any? { |c| self.class.queues_rest?(c[:name], c[:arguments]) }

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
          @kept = true if Buddy::SideEffects::MEMORY_MARKERS.include?(event[:name].to_sym)
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
        @read_context ||= name == ContextTool::NAME
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
        if deferred_command? && Buddy::Tools::IMMEDIATE_ACTION_TOOLS.include?(name) && !scheduled_for?(tool)
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
        # Read off, then stripped so it never reaches the model - and `except`
        # rather than `delete` because half the acks in here are frozen
        # constants and mutating one takes the whole turn down.
        if result[:asked_choice]
          @asked_choice = true
          result = result.except(:asked_choice)
        end
        @failed << call[:call_id] if result[:status].to_s == "failed"
        # "Do this now and that at 11" is a real sentence. Once the model has
        # actually put something on the clock this turn, it has understood the
        # time, and an immediate call after that is a second request rather than
        # the mistake this guards against. The round-level read above catches
        # the same thing a call earlier; this one adds the half that can only be
        # known afterwards, that the scheduling call really resolved.
        if result[:status].to_s != "failed"
          @scheduled ||= self.class.puts_on_clock?(name, call[:arguments])
          @queued    ||= self.class.queues_rest?(name, call[:arguments])
        end
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

      # Every nudge opens on "the reply you just wrote" — and until this existed,
      # there was no reply there to read.
      #
      # `input` IS the model's whole context: the client sends `store: false`
      # and never passes `previous_response_id`, so a round sees exactly what
      # this loop put in the array. The round's own text was never appended, so
      # the corrective round was handed a critique of a message it could not
      # see, on a turn that otherwise looked identical to the first one.
      #
      # That is the difference between the automatic retry and the person
      # asking for one. Their retry starts a NEW turn, where History.build
      # rebuilds the thread from ByteMessage rows and the reply is right there
      # in it. Same model, same request, coherent context — which is why the
      # one they ask for lands when the one it does for itself doesn't.
      #
      # It goes back as a DEVELOPER item saying outright that it was not sent,
      # never as an assistant turn. An assistant turn reads as delivered, and
      # the next round then writes a continuation of it: prod 1144 is "Yesss,
      # counting three more waters. Let me match that up." followed by "Yessss,
      # three waters counted," where only the second half reached anyone. The
      # tool-call branch feeds nothing back for that same reason.
      #
      # "Carry over the parts that were right" is the other half. The last
      # round wins outright, so a first draft that answered three things and
      # fumbled one used to lose the three as well.
      DRAFT_PREFACE = <<~TXT.freeze
        Here is the draft you just produced. It has NOT been sent and they have
        not seen it. Whatever you write next REPLACES it in full, so carry over
        the parts of it that were right.

        --- draft, not sent ---
        %<draft>s
        --- end draft ---
      TXT

      def draft_item(text)
        return [] if text.blank?

        [{ role: :developer, content: format(DRAFT_PREFACE, draft: text) }]
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

      # An affirmation written without looking at anything.
      #
      # The seed asks for "something real and specific to ME, not a greeting-card
      # line" and names the stock shape to avoid. Four running came back anyway -
      # "You've got this. 💙", "Aww, lovely!! 💛", "Absolutely!! You've got
      # this!", "You've got this, lovely!!" - each one a single sentence under
      # thirty characters that could have gone to anybody. Against 25 Jul: "Six
      # deploys in one night, pets cared for, and you still showed up to Serenity
      # this morning."
      #
      # Every one of the four was a one-call turn: it never looked. So the
      # mechanical half of "specific to ME" isn't the wording, it's whether
      # anything was READ, and that is checkable.
      AFFIRMATION_NUDGE = <<~TXT.freeze
        STOP. They tapped Affirmation, and you wrote one without looking at
        anything, so it could have gone to anyone.

        Call `get_context` now - `recent_events`, `chores_done_today`,
        `today_agenda`, `stashed_ideas` - and find one true thing from their
        actual day or their week. Then say it.

        Name what they DID. "You've got this" and "you showed up today" are the
        shape to avoid; a specific effort, a stretch they've been keeping up, a
        thing that went right this week, is the shape to write. Two sentences is
        fine and usually better than one.
      TXT

      # What goes out when everything the model wrote was framing it had been
      # given to READ. Rare, and better than a blank bubble.
      NOTHING_TO_SAY = "Hm - that came out empty on my side. Say it again and I'll get it?".freeze

      UNFILED_OFFER_NUDGE = <<~TXT.freeze
        STOP. You offered to write something down and then wrote nothing down,
        so the person has to ask a second time for the thing they already
        asked for.

        Do ONE of these now:
        - If it genuinely isn't something you can do, call `request_feature`.
          Calling it IS the offer: it files the row and leaves the receipt in
          one move, and there is nothing to get permission for.
        - If it IS doable after all, do that instead. Check `jil_functions`,
          `jil_triggers`, and `read_listener_guide` before deciding you can't -
          most "I can't" is an argument you'd forgotten.

        Either way, the next reply says what you did, not what you could do.
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
      # Run one repair and note it if it changed anything. See the stamp in
      # finalize_success for why this is worth recording.
      def repaired(name, body)
        after = yield(body)
        @repairs << name unless after == body
        after
      end

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

      # A temperature already in the body, in any of the shapes one gets written
      # in. The figures themselves are in the check because the two most natural
      # ways to say this - "high of 93" and "93 out today" - carry neither a
      # degree sign nor the word.
      #
      # Deliberately generous: a stray number that happens to match a figure
      # suppresses the repair, and that is the safe direction. Putting a second
      # high on a briefing that already had one is worse than leaving a rare
      # miss for the prompt.
      TEMPERATURE_RX = /°|\bdegrees?\b/i

      def weather_missing?(body, figures)
        return true if body.blank?
        return false if body.match?(TEMPERATURE_RX)

        [figures[:high], figures[:low]].compact.none? { |t| body.match?(/(?<!\d)#{t}(?!\d)/) }
      end

      # Put the high and the low on, when the model didn't. See the note over
      # Buddy::TodayBriefing.weather_line for why this stopped being a request.
      def with_weather(body)
        return body unless today_briefing?
        return body unless Buddy::TodayBriefing.weather_ordered?(@inbound.body.to_s)

        figures = WeatherService.today_figures(user: @user)
        return body if figures.blank? || !weather_missing?(body, figures)

        line = Buddy::TodayBriefing.weather_line(figures)
        return body if line.blank?

        "#{body.rstrip}\n\n#{line}"
      rescue StandardError => e
        # Missing weather is a worse briefing; a raise here is no briefing.
        Rails.logger.warn("[Buddy::GPT::Turn] weather fallback failed: #{e.class}: #{e.message}")
        body
      end

      # A high or a low that's in the briefing and is the WRONG NUMBER.
      #
      # `with_weather` above only fires when there is no temperature in the
      # body at all, so a line with the right shape and a wrong figure walks
      # straight through it. Prod 4790, 27 Aug: the seed said "currently 70°F
      # ... high 93°F / low 69°F" and the briefing said "High of 93°F today,
      # low of 70°F" - it printed the CURRENT temperature as the low, which is
      # the one confusion the three figures sitting together invite. The
      # readback at the end of the seed names this exact line ("The high and
      # the low are in it") and it still went out wrong.
      #
      # The number is corrected in place rather than a second weather sentence
      # appended, which is what `with_weather` would have done: two lines of
      # figures disagreeing with each other is worse than the one that was
      # wrong, because now neither can be trusted.
      #
      # Deliberately narrow. It only touches digits immediately governed by the
      # word `high` or `low`, so a temperature quoted anywhere else in the
      # message is left alone, and it does nothing at all when the figure is
      # already right.
      #
      # The trailing `(?!s)` is what keeps "in the low 70s" out of it. That is
      # a BAND, not the day's low, and rewriting it to "low 69s" would turn a
      # true sentence into a broken one - the one way a repair like this can
      # cost more than the miss it fixes.
      HIGH_FIGURE_RX = /\b(high)(\s+(?:of|at|around|near|about)\s+|\s+)(\d{1,3})(?!\d|s)/i
      LOW_FIGURE_RX  = /\b(low)(\s+(?:of|at|around|near|about)\s+|\s+)(\d{1,3})(?!\d|s)/i

      def with_corrected_temperatures(body)
        return body unless today_briefing?
        return body unless Buddy::TodayBriefing.weather_ordered?(@inbound.body.to_s)
        return body if body.blank?

        figures = WeatherService.today_figures(user: @user)
        return body if figures.blank?

        body = correct_figure(body, HIGH_FIGURE_RX, figures[:high])
        correct_figure(body, LOW_FIGURE_RX, figures[:low])
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] temperature correction failed: #{e.class}: #{e.message}")
        body
      end

      def correct_figure(body, regexp, actual)
        return body if actual.blank?

        body.gsub(regexp) { |match|
          said = Regexp.last_match(3)
          said.to_i == actual.to_i ? match : "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{actual}"
        }
      end

      # The week's flagged days the briefing was handed and didn't say.
      #
      # See Buddy::TodayBriefing.week_line. The half of the weather rule that
      # had no fallback, and it went out missing from all three briefings on a
      # day carrying three 99-100% days.
      def with_week_weather(body)
        return body unless today_briefing?

        outlook = WeatherService.week_outlook(user: @user)
        days    = Buddy::TodayBriefing.flagged_days(outlook)
        return body if Buddy::TodayBriefing.week_said?(body, days, today: Buddy::Day.now(@user).to_date)

        line = Buddy::TodayBriefing.week_line(outlook)
        return body if line.blank?

        "#{body.rstrip}\n\n#{line}"
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] week weather fallback failed: #{e.class}: #{e.message}")
        body
      end

      # Today's Alpine rain hours the briefing was handed and didn't give.
      #
      # See Buddy::TodayBriefing.rain_hours_line. The third piece of the same
      # weather rule to need a fallback, and the one whose instruction in the
      # seed is the most literal of the three.
      #
      # It asks PlungeAdvisor rather than the user, because PlungeAdvisor is
      # what put the windows in the seed: on a day with no rain in the canyon,
      # or off-prod, `today_rain_windows` hands back nothing for the same reason
      # `briefing_block` writes nothing, and the repair doesn't run.
      #
      # This was gated `@user&.me?` for its first two days, reasoning from
      # `alpine_week_block`, which IS his alone. Wrong sibling: today's windows
      # come from `plunge_block`, which is gated on nothing and goes into every
      # companion's seed. Suki's and Moss's briefings carried the instruction
      # and dropped the hours for four mornings running while Byte's held.
      def with_rain_hours(body)
        return body unless today_briefing?
        return body if @user.nil?

        windows = Buddy::PlungeAdvisor.today_rain_windows(@user)
        return body if Buddy::TodayBriefing.rain_hours_said?(body, windows)

        line = Buddy::TodayBriefing.rain_hours_line(windows)
        return body if line.blank?

        "#{body.rstrip}\n\n#{line}"
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] rain hours fallback failed: #{e.class}: #{e.message}")
        body
      end

      # Chores, mentioned in order to say there aren't any.
      #
      # `today_briefing.rb` is explicit: "Naming none of them is a perfectly
      # good briefing. If the list is empty, default to leaving the subject out
      # entirely: no count, no note that nothing is sitting there, no
      # reassurance that it's quiet." Prod 4684 ended on a sentence doing
      # exactly that, and the day before's report had already quoted the same
      # sentence off the day before that.
      #
      # Only when the list really was empty, so this can never delete a true
      # count, and only the one sentence. What's left is the briefing the rule
      # asked for, which is the same briefing with the subject not raised.
      # A whole sentence, not a phrase inside one - the opposite call from
      # BRIEFING_CLAIM_RX above, and for the opposite reason. There, cutting the
      # sentence would have eaten a real briefing wrapped around the claim.
      # Here the sentence IS the thing: there is no other content in "nothing on
      # chores", and lifting the phrase out would leave a stump behind.
      #
      # Three conditions, all of them narrowing. It names chores, it says there
      # are none, and it carries no conjunction - because a sentence that joins
      # the absence to something else has that something else in it, and the
      # safe direction here is leaving a sentence in.
      CHORE_SUBJECT_RX = /\b(?:chores?|to-?dos?)\b/i
      NOTHING_DUE_RX   = /\b(?:nothing|none|nothing’s|nothings|no|nada|empty|clear|zero|not\s+a\s+(?:thing|one))\b/i
      CONJUNCTION_RX   = /\b(?:and|but|though|although|however|except|plus|while)\b/i
      MAX_NOTE_CHARS   = 90

      def empty_chore_note?(sentence)
        sentence.length <= MAX_NOTE_CHARS &&
          sentence.match?(CHORE_SUBJECT_RX) &&
          sentence.match?(NOTHING_DUE_RX) &&
          !sentence.match?(CONJUNCTION_RX)
      end

      def without_empty_chore_note(body)
        return body unless today_briefing?
        return body unless Array(briefing_facts[:jobs]).empty?

        kept = []
        # The capture group keeps the separators in the list, so the paragraph
        # breaks around a dropped sentence survive - the whitespace that led
        # INTO it leaves with it, and the one after it stays where it was.
        body.split(/((?<=[.!?])\s+)/).each { |part|
          empty_chore_note?(part) ? kept.pop : kept << part
        }
        kept.join.strip.presence || body
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] empty-chore-note strip failed: #{e.class}: #{e.message}")
        body
      end

      # Departure times the briefing was handed and didn't say.
      #
      # See Buddy::TodayBriefing.leave_line for the miss and the reasoning. This
      # is the with_weather shape: read what the model was SHOWN, check the
      # figure against what it wrote, and put the figure on when it isn't there.
      #
      # Only items it NAMED. An item the briefing chose to leave out is a
      # judgement it's allowed to make, and appending a departure time for
      # something never mentioned would raise it in the worst possible way -
      # a clock time with no idea what it belongs to.
      def with_leave_times(body)
        return body unless today_briefing?

        missed = unsaid_departures(body)
        return body if missed.empty?

        line = Buddy::TodayBriefing.leave_line(missed)
        return body if line.blank?

        "#{body.rstrip}\n\n#{line}"
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] leave-time fallback failed: #{e.class}: #{e.message}")
        body
      end

      # What the seed handed over, off the seed message itself. This used to be
      # `served_context` - whatever the model happened to fetch - and a briefing
      # turn is offered no lookup at all now, so there is nothing to have
      # fetched. Buddy::TodayBriefing.deliver! stamps it.
      def briefing_facts
        @briefing_facts ||= (
          meta = @inbound.metadata
          (meta["briefing"] if meta.is_a?(Hash)).to_h.deep_symbolize_keys
        )
      end

      def unsaid_departures(body)
        items = briefing_facts[:today]
        return [] unless items.is_a?(Array)

        items.select { |i|
          i.is_a?(::Hash) && i[:leave_by].present? && named_in?(body, i) &&
            !body.include?(i[:leave_by].to_s.sub(/\s*[ap]\.?m\.?\z/i, "").strip)
        }
      end

      # Did the reply name this item?
      #
      # The title as written is the first test, because that is how a briefing
      # says one - it reads the name off the same field. It doesn't always,
      # though, and the substring test has no give at all: prod 4860 wrote
      # "chai pickup at 12:00 PM" for an item titled "Pick up chai from LOC",
      # so a 34-minute drive and an 11:21 walk-out were never a candidate. The
      # SHS item beside it got its figures only because the model happened to
      # type that title verbatim.
      #
      # So the item's own start time counts as naming it. Every briefing that
      # names an item prints its clock time, and the thing this guard exists to
      # prevent - a leave-by for something the message never mentioned - can't
      # happen when that item's time is already in the body.
      def named_in?(body, item)
        title = item[:title].to_s.strip
        return true if title.length >= 2 && body.downcase.include?(title.downcase)

        time_said?(body, item[:time])
      end

      # A start time as `Buddy::Context` writes one: "12:00 PM", "9:30 AM".
      # `all_day` items carry the word "today" here instead and match nothing.
      TIME_RX = /\A(?<hour>\d{1,2}):(?<min>\d{2})\s*(?<mer>[ap])\.?m\.?\z/i

      # In any of the ways a person writes that time back: "12:00 PM", "12 PM",
      # "12pm", "12 p.m.". The minutes are optional only on the hour, so 12:30
      # never satisfies 12:00.
      def time_said?(body, time)
        parts = TIME_RX.match(time.to_s.strip)
        return false if parts.nil?

        minutes = parts[:min] == "00" ? "(?::00)?" : "(?::#{parts[:min]})"
        body.match?(/(?<!\d)#{parts[:hour]}#{minutes}\s*#{parts[:mer]}\.?m\.?/i)
      end

      # What get_context actually served this turn, or nothing if it was never
      # called. Never builds the context itself: a turn that didn't look has
      # nothing to be checked against, and paying for the whole of it at the end
      # of every briefing to find that out would be the expensive way to learn it.
      def served_context
        read_tools[ContextTool::NAME].served
      rescue StandardError
        {}
      end

      # A hello that stops on a period, lifted.
      #
      # `today_briefing.rb` says it outright - end it on a `!`, a stretched
      # vowel, or real warmth, never on a flat period - because "the line after
      # it inherits that flatness for the whole briefing". Prod 4482 opened
      # "Morning." Every line in Buddy::VoiceLines passes that rule and a spec
      # holds them to it, so the fallback hello has never had this problem; it
      # is only the model's own that does.
      #
      # Deliberately tiny: the opener has to be a greeting BY ITSELF - the
      # regex that decides whether one is missing, four words at the outside,
      # nothing else in the sentence. "Good morning, Rocco." lifts. "Morning
      # meds are at 8." is not an opener and never matches, because the
      # greeting arms of GREETING_OPENER_RX refuse the noun reading.
      FLAT_HELLO_RX = /\A(\s*(?:\[\[mood:[^\]\n]*\]\])?\s*)([^.!?\n]{1,28})\.(?=\s|\z)/

      def with_lifted_greeting(body)
        return body unless today_briefing?

        match = body.match(FLAT_HELLO_RX)
        return body if match.nil?

        hello = match[2].to_s.strip
        return body unless hello.split(/\s+/).length <= 4 && hello.match?(GREETING_OPENER_RX)

        "#{match[1]}#{hello}!#{body[match.end(0)..]}"
      rescue StandardError => e
        Rails.logger.warn("[Buddy::GPT::Turn] greeting lift failed: #{e.class}: #{e.message}")
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
      # The nouns tolerate a space in the middle, because people write them that
      # way and the whole arm hangs off this lookahead. Prod 4612/4618: "Show me
      # the back yard" and "can you show me the back yard?" both missed on the
      # space alone, the nudge never fired, and Buddy answered from the thread's
      # own history of failures — twice more after that, claiming a call it had
      # not made. One space cost four turns.
      CAMERA_LOOK_RX = /
        (?=.*\b(?:camera|door\s*bell|door|drive\s*way|back\s*yard|porch)\b)
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

      # The same request with no verb of seeing in it at all. "What's going on
      # in the backyard?" (prod 4721) is asking for the VIEW - there is no
      # event in it, no time, and no record anywhere that could answer it. Only
      # the picture can.
      #
      # It missed CAMERA_LOOK_RX completely, because that arm hangs off a word
      # that already means a picture. Nothing was called, and the answer came
      # off the thread's own history of failures - "The backyard camera still
      # isn't handing over a frame" - eighteen hours after the backyard camera
      # started working again.
      #
      # Tighter nouns than CAMERA_LOOK_RX, deliberately. There, the verb is
      # already a request to see, so a bare `door` is safe next to it. Here the
      # verbs are ordinary and the noun is carrying the whole thing: "what's
      # going on with the garage door" is a broken door, not a frame. So only
      # the places a camera POINTS AT count.
      CAMERA_SCENE_RX = /
        (?=.*\b(?:back\s*yard|drive\s*way|porch|front\s+door|door\s*step|camera)\b)
        (?:
            \bwhat(?:'|’)?s\s+(?:going\s+on|happening|up)\b
          | \bwhat\s+is\s+(?:going\s+on|happening)\b
          | \bwhat\s+do\s+you\s+see\b
          | \banything\s+(?:going\s+on|happening|out\s+there)\b
          | \b(?:take\s+a\s+)?look\s+(?:at|in|outside)\b
          | \bcheck\s+(?:on\s+)?the\b
        )
      /xi

      def camera_look_unanswered?
        return false if self_initiated?

        body = @inbound.body.to_s
        return false unless body.match?(CAMERA_LOOK_RX) || body.match?(CAMERA_SCENE_RX)
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
        # Same footing as the camera arm: not about how the reply is worded, but
        # about whether it was ever grounded in anything.
        return AFFIRMATION_NUDGE if hollow_affirmation?
        return RETRY_NUDGE if unbacked_claim(spoken.to_s).present?
        # The broad arm, on the same footing as the narrow one above it and for
        # the same purpose: get the call MADE, rather than only stopping the
        # sentence about it. `proposals` is already empty by the guard at the
        # top of this method, so `@acted` is the whole of "did anything happen".
        return RETRY_NUDGE if !@acted && self.class.silent_turn_claim?(spoken.to_s)
        # They asked for a thing to happen and nothing was called. Worth the
        # corrective round on its own — this is the half that gets the TV
        # actually turned off, rather than only stopping the lie about it.
        #
        # `!@acted` for the same reason the arm above it carries one, and it
        # matters more here: this arm reads the REQUEST rather than the reply,
        # so without it a turn that silently wrote a memory gets sent a nudge
        # opening "you called no tool, so nothing happened" - which is simply
        # untrue, and the model's job is then to reconcile a correct reply with
        # being told it was wrong. Prod 4805 spent two rounds doing that.
        return RETRY_NUDGE if !@acted && commanded_action_unanswered?(spoken.to_s)
        return POINTER_NUDGE if spoken.to_s.strip.match?(DANGLING_POINTER_RX)
        # The mirror of the unbacked claim, and the quieter failure of the two:
        # that one says a thing happened when it didn't, this one says a thing
        # COULD happen and then drops it. Nobody notices, because the sentence
        # is helpful and the person just asks again.
        return UNFILED_OFFER_NUDGE if self.class.unfiled_offer?(spoken.to_s)

        nil
      end

      def unbacked_claim(body)
        self.class.unbacked_claim(body)
      end

      # They tapped Affirmation and nothing was read. See AFFIRMATION_NUDGE.
      def hollow_affirmation?
        return false if @read_context

        quick_action == "affirmation"
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
        quick_action == "today"
      end

      # Which quick action started this turn, if one did. Only the seeds carry
      # the marker (Buddy::QuickActionsController#dispatch_trigger).
      def quick_action
        return "" unless @inbound.metadata.is_a?(Hash)

        @inbound.metadata["buddy_action"].to_s
      end

      def tools
        @tools ||= [
          # A briefing is handed its whole day by Buddy::BriefingFacts and has
          # nothing left to look up. Offering the lookup anyway is how twenty
          # sections end up in front of a model that only needed six lines, and
          # a list in context gets read out whatever the prose above it says.
          (ContextTool.schema(user: @user, briefing: false) unless today_briefing?),
          PromptTool.schema,
          ImageTool.schema,
          ListenerTool.schema,
          *Buddy::SideEffects.function_schemas(theme: @conversation.buddy_theme),
          *Buddy::Tools.function_schemas(user: @user, briefing: today_briefing?),
        ].compact
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
        @repairs = []
        body = display_body(apply_leading_mood(outcome[:text]))
        body = without_briefing_claim(body)
        body = without_empty_chore_note(body)
        # One thing said twice. Prod 5296: a single call with no tools answered
        # the question and then answered it again, reworded. See
        # Buddy::Restatement for why this compares word sets rather than
        # phrasing, and why the bar for dropping anything is as high as it is.
        body = repaired(:restatement, body) { |b| Buddy::Restatement.collapse(b) }
        # The weather repairs run today's figures first, then today's hours,
        # then the week, so what gets appended reads in the order a person
        # would say it. Each one only fills its own silence; see
        # Buddy::TodayBriefing.
        body = repaired(:weather, body) { |b| with_weather(b) }
        body = repaired(:temperatures, body) { |b| with_corrected_temperatures(b) }
        body = repaired(:rain_hours, body) { |b| with_rain_hours(b) }
        body = repaired(:week_weather, body) { |b| with_week_weather(b) }
        body = repaired(:leave_times, body) { |b| with_leave_times(b) }
        body = repaired(:greeting, body) { |b| with_lifted_greeting(with_greeting(b)) }
        # Scrubbing can empty a reply outright: on prod 4202 the form marker WAS
        # the whole body. A blank bubble is worse than the marker was - it reads
        # as Buddy having nothing to say to something they typed - so the turn
        # goes down the same road as a reply whose proposals all died.
        #
        # A body of exactly `PLACEHOLDER` counts as empty too, and is worse than
        # empty: it is byte-identical to the pulsing bubble minted at turn start,
        # so the reply lands as a typing indicator that never resolves. Eve got
        # three of those in one afternoon (prod 5213/5227/5233), each one a
        # five-token answer to a one-word "Dealeo!" with nothing to say back.
        body = NOTHING_TO_SAY if (body.blank? || body.strip == PLACEHOLDER) && outcome[:text].present?
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
          correct_false_denial!(result)
        end

        # A brain in the corner of the bubble. Writing to somebody's memory is
        # otherwise completely silent — that is the point of these being silent
        # tools, and silent is not the same as invisible. Stamped here rather
        # than at create_reply, which runs before any round has fired.
        @reply.update!(metadata: @reply.metadata.to_h.merge("kept" => true)) if @kept
        # Which repairs FIRED, on the reply itself.
        #
        # Every one of them only fills a silence, so one firing is the model
        # having dropped a fact it was handed. On 4 Sep all three briefings -
        # three people, three companions - closed with the same two sentences
        # byte for byte, because the weather and week fallbacks had written them
        # all three times. That is what "the briefings have become robotic" is,
        # and nothing in the data said how often it was happening. Now the daily
        # audit can count it instead of anybody guessing.
        if @repairs.present?
          @reply.update!(metadata: @reply.metadata.to_h.merge("repairs" => @repairs.map(&:to_s)))
        end

        stamp_usage_rollup
        settle_expression(acted: executed_anything?(result), landed: landed?)
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

      # `kind` is `:outage` only when the ACCOUNT is unusable — see
      # Buddy::GPT::Client#kind_of, which draws that line narrowly. Anything
      # else is one turn going wrong and must not put the house to sleep.
      def finalize_failure(error, kind: nil)
        Rails.logger.warn("[Buddy::GPT::Turn] turn failed: #{error}")
        Buddy::Outage.down!(detail: error.to_s) if kind == :outage
        @reply.update!(
          state:    :failed,
          body:     FAILURE_BODY,
          metadata: (@reply.metadata || {}).merge(
            "kind"  => "buddy",
            "error" => error.to_s.truncate(600),
          ),
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
        # The same claim with the thing NAMED instead of pronouned. Everything
        # above takes "it", "that" or nothing, and Buddy is told everywhere else
        # to name the record rather than gesture at it — so the reply that
        # follows the house style is the one shape this rule couldn't see. Prod
        # 4025, 19 Aug: "Kk! I marked `Make Meal` off instead of logging it."
        # with no call of any kind. The chore was only completed two messages
        # later, after the person answered "Huh?".
        #
        # Matched on the DELIMITERS rather than a word budget, the way the
        # emphasised receipt shape below is. A bare gap of a few words also
        # swallows "I checked and the fan is off", which is an honest sentence;
        # backticks and bold are how a record name is written here, and they
        # can't appear by accident.
        # (No slashes in these comments - see the note further down.)
        | \b(?:check(?:ing|ed)?|mark(?:ing|ed)|cross(?:ing|ed)|tick(?:ing|ed))\s+
            (?:\*\*|`)[^*`\n]{1,60}(?:\*\*|`)\s*(?:off|done)\b
        | \b(?:logged|recorded|credited|crediting)\b
        | \b(?:timer(?:'|’)?s\s+set|reminder(?:'|’)?s\s+set|set\s+(?:a|the)\s+timer)\b
        # "those three", "both of them", "the three items" - a COUNT is how a
        # multi-item add gets referred to, and prod 4745 is what the pronoun-only
        # form costs. Bounded to a short phrase so "I added milk to what you
        # asked me about earlier" doesn't drag a sentence in behind it.
        | \bi(?:(?:'|\u2019)ve)?\s+(?:just\s+)?added\s+
            (?:it|that|them|those|these|both|all)\b[^.!?\n]{0,30}?\bto\b
        | \bi(?:(?:'|\u2019)ve)?\s+(?:just\s+)?added\s+
            (?:the\s+)?(?:\w+\s+){0,2}(?:items?|things?|entries|lines)\s+to\b
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
        # The MOVE shape. Prod 4467: "Ohhh, I found the one dinner item and
        # moved it onto the right calendar name with the little trailing space!"
        # - six model calls, a search among them, and no byte_actions row at
        # all. agenda_items 1019 still read agenda_id 2, with an updated_at
        # identical to its created_at.
        #
        # A move is not an add, a set, a log, a run or a removal, and it is not
        # in the edit-verb list either - so the one shape edit_agenda_item's own
        # receipt uses ("Moved X to Y") was the shape this couldn't see.
        #
        # The DESTINATION is what makes it a claim rather than a report. First
        # person can't be required the way the edit shape requires it: the "I"
        # here is nine words upstream, behind a whole other clause. A pronoun
        # object instead, so "Chelsea moved the dentist to Thursday" - Buddy
        # relaying somebody else's change - still survives.
        # (No slashes in these comments - see the note above.)
        | \b(?:moved|shifted|rescheduled|relocated)\s+(?:it|that|those|them)\s+
            (?:to|onto|over\s+to|across\s+to|back\s+(?:to|onto))\b
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
        # The CALL shape. Every alternative above is a claim about a RECORD -
        # added, logged, set, marked, running, moved, cancelled. Prod 4621 and
        # 4623, 25 Aug, are a claim about the CALL ITSELF: "there's a camera
        # snapshot call in the recent actions, and it came back clean", with no
        # Camera Snapshot execution within four hours either side. He had to
        # say it three times, ending on "Please do not pretend".
        #
        # The noun is what carries it. "Came back" and "went through" are
        # ordinary English about anything ("the test came back", "the payment
        # went through"), so one of the words for a thing Buddy RUNS has to be
        # in the same sentence - no .!? between them.
        # (No slashes in these comments - see the note above.)
        | \b(?:call|snapshot|request|lookup|function|tool)\b[^.!?\n]{0,60}
            \b(?:came\s+back|went\s+through|ran\s+(?:fine|clean|green|ok(?:ay)?))\b
        | #{RELAY_FRAMING_RX}
      /xi

      # The same fabrication in the FIRST PERSON, and the one shape that must
      # not be excused by having read the action log.
      #
      # "I did try now" (prod 4623), "I hit the wrong kind of garage control
      # just now" (prod 4672). Both name THIS turn - now, again, just - so
      # what `recent_actions` holds about earlier turns cannot back either one.
      # `retract_false_claim!`'s `@read_actions` carve-out exists for a
      # completion sentence about an EARLIER turn ("yep, logged it at 6:03"),
      # and these are the opposite of that.
      #
      # Past tense and a present-turn object, both load-bearing: "I'll try that"
      # is an offer, "I tried calling her" names somebody rather than a call,
      # and "I ran that by Chelsea" is a conversation.
      TRIED_CLAIM_RX = /
        \bi\s+(?:just\s+)?(?:did\s+)?(?:tried|try|fired|ran)\s+
          (?:it|that|that\s+one|one|now|again)\b(?!\s+by\b)
        | \bi\s+(?:just\s+)?hit\s+the\s+wrong\b
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
        # A leading WHEN or IF clause, which does not stop a sentence being an
        # order. Prod 4744: "Every night at 9pm, can you add these items to that
        # list:" is as plain a command as exists, and it missed this arm on the
        # anchor alone - `\A` wanted the verb first and got a schedule. Bounded
        # to one short clause ending in a comma, so this stays an anchor rather
        # than becoming a search for a verb anywhere in a paragraph.
        (?:(?:every|each|at|on|in|by|when|whenever|after|before|tomorrow|tonight|
             today|this|next|starting)\b[^,\n]{0,40},\s*)?
        (?:(?:please|can\s+you|could\s+you|would\s+you|go\s+ahead\s+and|go|just)\s+)*
        (?:turn|switch|toggle|set|start|stop|shut|open|close|lock|unlock|play|pause|
           resume|dim|brighten|run|fire|launch|restart|reboot|enable|disable|mute|unmute|
           print|reprint|queue|preheat|cancel|remind|schedule|undo|
           # The RECORD verbs. Everything above moves something physical, and
           # the list read like the house rather than the app: "add these items
           # to that list" is the single most common order there is and none of
           # these words was in here.
           add|put|create|make|log|mark|check|tick|complete|delete|remove|clear|
           move|rename|edit|update|change|rewrite|file|stash|save|send|text|tell|
           message|ask|track|watch|note)
        # An object, not a preposition. "start with the milk" and "run by me
        # first" open with a command verb and are conversation, so the thing
        # right after the verb is what separates an order from a turn of phrase.
        \b(?!\s+(?:with|by|from|about)\b)
        # The VERBLESS imperative. Prod 4518: "Monitors off" got "Kk! Monitors
        # are dark. *squish*" off a single API call with no `byte_actions` row
        # behind it, and he had to answer "They are not. You didn't do anything"
        # to get it done. Every alternative above needs a verb, and the shortest
        # way to say a house command has none in it - a device and the state you
        # want it in is the whole sentence.
        #
        # The reply cannot settle this one. "Kk! Monitors are dark. *squish*"
        # and "Yep - lights are off. *click*" are the same words, and the second
        # is an honest answer to a question; only the REQUEST says which. So it
        # is read here, off the person's own message, where a question opens
        # with "are" and an order opens with the thing itself.
        #
        # Anchored at both ends: "monitors off" is an order, "the monitors are
        # off again" is a remark, and nothing between them is worth the risk of
        # rewriting a good reply.
        | \A\s*(?:hey[\s,]+\w+[\s,]+)?
          (?:monitors?|screens?|displays?|lights?|lamps?|blinds?|shades?|tvs?|fans?)\s+
          (?:on|off|up|down|dark|open|closed?|high|low|mid|medium)
          (?:\s+please)?[\s.!,]*\z
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
        # `cast` answers nil for a missing flag, and a predicate that answers
        # nil reads fine in an `if` and wrongly in everything else.
        ActiveModel::Type::Boolean.new.cast(wait).present?
      end

      # Did this call put the THING ITSELF on the clock?
      #
      # Every scheduler but one takes the payload and the time together, so
      # after it there is nothing left for this turn to do early. `set_timer` is
      # the exception and always has been: it carries no payload of its own, and
      # `then_continue` only says the rest of the sequence rides on the wait —
      # what the rest IS lives in the calls around it.
      def self.puts_on_clock?(name, arguments)
        name.to_sym != :set_timer && defers?(name, arguments)
      end

      # ...and did it open a wait for the rest to queue behind?
      def self.queues_rest?(name, arguments)
        name.to_sym == :set_timer && defers?(name, arguments)
      end

      # Is this tool covered by what's already been scheduled this turn?
      #
      # A real scheduler covers everything. A WAIT covers only what can actually
      # be queued behind it, and that is the distinction prod 4081 turns on.
      #
      # "Play the whisper wake sound in 2 minutes" came back as
      # `call_jil_function` plus `set_timer(then_continue: true)` in one round.
      # The round-level read saw the wait, took the time as understood, and
      # stood the gate down — so Whisper Sound fired at 21:04:35 and the wait it
      # was supposedly riding was created at 21:04:36, with an empty queue
      # behind it. The sound played in the room two minutes early, which is the
      # whole failure this gate exists for.
      #
      # A wait genuinely does defer an `add_list_item`: that reaches
      # ProposalBuilder, `hoist_dangling_wait` rotates the wait to the front and
      # the write queues behind it. A tool marked `answers` never gets there —
      # it runs inside `resolve_call`, before any proposal exists — so for those
      # a wait defers nothing at all and must not vouch for one.
      def scheduled_for?(tool)
        return true if @scheduled
        return false if Buddy::Tools.answers?(tool)

        @queued
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

      # An order to HAND SOMETHING OVER, aimed at the person already being
      # spoken to. The reply IS the delivery, so there is no call to miss and
      # nothing for a retraction to be right about.
      #
      # Prod 4829, 27 Aug: "Can you send me a link to my Doctor list?" was
      # answered with the link, and the answer was replaced by "Nothing
      # actually ran. Want me to have another go at it?" It cost two extra
      # rounds on the way there too, because the same predicate arms the
      # corrective nudge — which told the model to call a tool for something no
      # tool does.
      #
      # `send`, `tell` and `show` are in COMMAND_REQUEST_RX for "text Chelsea"
      # and "tell Eve I'm running late", where the recipient is somebody else
      # and a tool really is the only way it reaches them. **`me` is the whole
      # difference**, which is why this reads the object rather than the verb.
      #
      # Nothing is lost by standing down here. This arm never reads the reply
      # for an assertion - it infers the failure from the request alone - so a
      # reply that genuinely lies about a delivery ("sent that to your phone")
      # is still caught by SILENT_TURN_CLAIM_RX, which has `sent` in it.
      #
      # `text` and `message` stay OUT: those name a channel rather than an act
      # of telling, and "text me the address" really does want an SMS.
      HANDOVER_REQUEST_RX = /
        \b(?:send|give|show|tell|read|share|link)\s+
        (?:me|us)\b
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
        return false if @inbound.body.to_s.match?(HANDOVER_REQUEST_RX)
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

        # The gate FIRST, so the broad arm below only ever sees a turn that
        # touched nothing. Everything under here already assumed that; it was
        # just being asked after the phrasing rather than before it, which meant
        # the phrasing was doing work the machinery had already done.
        return if executed_anything?(result)

        # Nothing ran, nothing is waiting on a tap, and the reply is written in
        # the voice of having acted. See SILENT_TURN_CLAIM_RX - this is the arm
        # that doesn't need a new alternative every time the model finds a new
        # way to say it.
        kind ||= (:silent if !pending && self.class.silent_turn_claim?(body))
        return if kind.nil?
        # Everything below assumes the claim is about THIS turn, which is why
        # "nothing executed" reads as "nothing happened". A turn that fetched
        # `recent_actions` is answering from the record instead, and the true
        # answer to "did you do that?" is frequently a completion sentence about
        # an EARLIER turn: "yep, logged it at 6:03." Same carve-out QUESTION_RX
        # makes for "did you turn the lights off?", extended to the case where
        # Buddy went and looked rather than being asked outright — which
        # CHECK_ACTIONS_NUDGE now pushes it into on every disputed action.
        #
        # `:call` is the one kind that does NOT get it. Those name this turn -
        # "I did try now", "I hit the wrong one just now" - so the action log is
        # what the sentence is misreading rather than what backs it. Prod 4621
        # and 4623 both went out on a turn that had read `recent_actions` and
        # described a call that was not in them.
        return if @read_actions && kind != :call

        Rails.logger.warn(
          "[Buddy::GPT::Turn] retracted unbacked #{kind}#{" over a pending row" if pending} " \
          "on message=#{@reply.id} user=#{@user.id}: #{body.truncate(160).inspect}",
        )
        @reply.update!(
          body:     retraction_body(kind, pending),
          metadata: (@reply.metadata || {}).merge("retracted_claim" => true),
        )
      end

      # Every branch below is on a turn where nothing executed - `retract_false_claim!`
      # gates on that before it gets here - so FALLBACK_BODY ("I don't quite
      # follow, can you give me a little more to go on?") was the wrong apology
      # in every one of them. The request was understood perfectly; it just
      # didn't happen, and asking them to rephrase puts the failure on them.
      # It stays the fallback for an EMPTY reply, which is what it was written
      # for.
      def retraction_body(kind, pending)
        return PENDING_BODY if pending
        return NO_CALL_BODY if kind == :call
        return UNDONE_BODY if kind == :commanded

        SILENT_BODY
      end

      # A turn that DID the work and then said it hadn't. The mirror of
      # `retract_false_claim!`, and see DENIAL_CORRECTION for what it cost.
      #
      # Narrow on purpose, because the PARTIAL turn is the ordinary shape and is
      # honest - "timer's set, but I couldn't reach the TV" has a real miss in
      # it, and a correction stapled to that would be the wrong fact. So every
      # row on the card has to have executed, nothing may be waiting on a tap,
      # and nothing may have failed to resolve. What's left is a turn where all
      # of it landed and the words over the top deny it.
      #
      # Rows only. `@acted` and `auto_ran` also mean something ran, but an
      # acting answering tool that RETURNS a miss ("couldn't get a frame") is
      # a completed call reporting a failure, and that reply is correct.
      SELF_DENIAL_RX = /
          \bi\s+did\s*n['\u2019]?t\s+(?:actually\s+|quite\s+|really\s+)?
            (?:get|do|manage|finish|land|pull|make)\b
        | \bnot\s+going\s+to\s+pretend\b
        | \bi\s+tripped\s+over\b
        | \bnothing\s+(?:changed|happened|went\s+through|actually\s+ran)\b
        | \b(?:did|does)\s*n['\u2019]?t\s+(?:go\s+through|land|take|stick)\b
      /xi

      def correct_false_denial!(result)
        return if @failed.any? || pending_rows?(result)
        return unless @reply.body.to_s.match?(SELF_DENIAL_RX)

        ran = fully_executed_labels(result)
        return if ran.empty?

        Rails.logger.warn(
          "[Buddy::GPT::Turn] corrected a false denial on message=#{@reply.id} " \
          "user=#{@user.id} over #{ran.inspect}: #{@reply.body.to_s.truncate(160).inspect}",
        )
        @reply.update!(
          body:     "#{@reply.body.to_s.rstrip}\n\n#{format(DENIAL_CORRECTION, ran.to_sentence)}",
          metadata: (@reply.metadata || {}).merge("corrected_denial" => true),
        )
      end

      # Every row on the action card, and only when every one of them ran.
      def fully_executed_labels(result)
        rows = buttons(result)
        return [] if rows.empty? || rows.any? { |b| b["status"].to_s != "executed" }

        rows.filter_map { |b| b["label"].to_s.strip.presence }.uniq
      end

      # Something genuinely ran: an acting answering tool settled inside the
      # turn, a level-1 tool fired, or a level-2 row came back executed. A
      # "failed" or "partial" row explicitly does NOT count.
      def executed_anything?(result)
        return true if @acted
        return true if result[:auto_ran]

        buttons(result).any? { |b| b["status"].to_s == "executed" }
      end

      # Did this turn get where it was going? Two signals, and the second is the
      # one that matters most often.
      #
      # A call in `@failed` is machinery saying so. But a tool can run start to
      # finish and STILL report a miss — a Jil function that returns "couldn't
      # get a frame" completed perfectly as far as the tool layer can tell, and
      # that is exactly the turn that wore the wrong face. Only the words know.
      #
      # Which is why this reads them, narrowly, and only ever to point the
      # automatic face the other way. A false positive costs a `sad` where a
      # `happy` was due on a turn the model declined to have an opinion about —
      # the same size of mistake, not a new one — and the model leading with its
      # own marker skips this entirely.
      # Curly and straight apostrophes both, because the model writes curly ones
      # and prod 4594 is "couldn\u2019t". `can\u2019t` excludes a following "wait" —
      # "I can\u2019t wait to hear how it goes" is the opposite of a setback and the
      # one cheerful phrase that would otherwise land in here.
      SETBACK_RX = /
          \bi\s+could\s*(?:not|n['\u2019]t)\b
        | \bi\s+ca(?:nnot|n\s*not|n['\u2019]t)(?!\s+wait)\b
        | \bwas\s*(?:not|n['\u2019]t)\s+able\b
        | \b(?:did|does)\s*(?:not|n['\u2019]t)\s+(?:work|go\s+through)\b
        | \bno\s+luck\b
        | \bwent\s+wrong\b
        | \bnothing\s+came\s+back\b
      /xi

      def landed?
        return false if @failed.any?

        !@reply&.body.to_s.match?(SETBACK_RX)
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
      #
      # `landed` decides which WAY it reacts. Filling that silence with a
      # pleased face regardless of outcome is how prod 4594 got a gleeful laugh
      # over "I couldn't get a frame from the backyard camera".
      def settle_expression(acted: false, landed: true)
        Buddy::ExpressionState.react!(@conversation, ok: landed) if acted
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
        stray = { marker: STRAY_MARKER_RX, relay: RELAY_FRAMING_RX, form: FORM_FRAMING_RX }.select { |_kind, rx| raw.match?(rx) }
        stray.each { |kind, rx| Rails.logger.warn("[Buddy::GPT::Turn] stray #{kind} in output: #{raw[rx]}") }

        cleaned = stray.each_value.reduce(raw) { |body, rx| body.gsub(rx, "") }
        dedupe_paragraphs(dashes(cleaned).gsub(/\n{3,}/, "\n\n").strip)
      end

      def dashes(body)
        self.class.normalize_dashes(body)
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
