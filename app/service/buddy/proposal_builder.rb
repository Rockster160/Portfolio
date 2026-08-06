module Buddy
  # Takes the model's proposal tool calls (see Buddy::GPT::Turn, which maps each
  # `function_call` to `{ tool_name:, payload: }`), validates them against
  # the tool registry, dedups/merges by tool.merge_key, and attaches ONE
  # ByteAction (multi_select: true) to the given Buddy reply message.
  # Each button row in the action carries { id, label, tool_name, payload,
  # status: "pending", count } — everything the executor needs to run and
  # everything the client needs to render.
  module ProposalBuilder
    module_function

    # How long a proposal checklist stays tappable. Long, because it lives in
    # the thread — the person may confirm it minutes or hours later.
    PROPOSAL_TTL = 3.days

    # The invisible action a WAIT parks its queue on, keyed to the timer that
    # will release it. Never mirrored into message metadata: there's nothing to
    # tap, and the countdown is already on screen.
    TIMER_GATE = "buddy_timer_gate".freeze

    # The same idea for a question put to another person: invisible, keyed to
    # the relay whose answer will release it.
    RELAY_GATE = "buddy_relay_gate".freeze

    # How long a sequence will wait on someone else to answer. A clock always
    # finishes; a person may simply not reply, and the rest of the sequence
    # can't sit pending forever waiting to find out.
    AWAIT_TTL = 3.days

    # Step kinds that never merge with a neighbour of the same kind: each one is
    # a separate wait, so "wait, X, wait, Y" has to nest rather than collapsing
    # into one wait with two things behind it.
    SOLO_KINDS = [:timer, :relay].freeze

    # Returns { action: <ByteAction or nil>, auto_ran: <bool> } so the caller
    # can pick the right expression: something to confirm (action present) vs
    # something already done (auto_ran) vs nothing.
    def create(user:, byte_message:, markers:)
      return { action: nil, auto_ran: false, forms: [] } if markers.blank?

      # Build validated per-marker proposals.
      raw = markers.filter_map { |m|
        tool = Buddy::Tools[m[:tool_name]]
        next nil if tool.nil?
        # A tool for a feature this person doesn't have is dropped exactly like
        # an unknown one. The model was never offered it, so this only fires on
        # a stale routine or a hand-built marker — either way it must not run.
        next nil unless Buddy::Features.allows_tool?(user, tool)
        # An answering tool reports to the MODEL, during the turn, and Turn
        # keeps it out of the proposals for exactly that reason. Reaching here
        # means a routine saved back when they were ordinary level-1 tools —
        # and there's no model turn left to report to, so running it now would
        # either chip a lookup it can't show or start a print nobody watched.
        next nil if Buddy::Tools.answers?(tool)

        payload, errors = Buddy::Tools.validate_payload(tool, m[:payload], zone: Buddy::Day.zone(user))
        next nil if errors.any?
        next nil unless Buddy::Features.allows_payload?(user, tool, payload)

        # A form tool's confirm is its PRE-SUBMIT gate and runs when the person
        # sends. Running it here rejects a half-filled form for being half-filled
        # — which is the entire thing a form exists to let them finish. Its
        # `fields` proc resolves it instead, inside FormAction.post!.
        if Buddy::Tools.form?(tool)
          next { tool: tool, payload: payload, count: 1, merge_key: safely { tool[:merge_key].call(payload) } || SecureRandom.uuid }
        end

        ctx = Buddy::ToolContext.new(user, conversation: byte_message.byte_conversation)
        confirm = safely { tool[:confirm].call(payload, ctx) }
        next nil if confirm.nil?

        resolved_payload = payload.merge(confirm[:resolved] || {})
        {
          tool:      tool,
          payload:   resolved_payload,
          # What was ASKED for, before confirm resolved names into ids. Kept
          # alongside because the two answer different questions: the resolved
          # payload is what to run now, and this is what the request meant —
          # which is the only half worth saving into a BuddyRoutine, since a
          # `task_id` captured today points somewhere else next month.
          args:      payload,
          count:     payload[Buddy::Tools::COUNT_ARG] || 1,
          merge_key: safely { tool[:merge_key].call(resolved_payload) } || SecureRandom.uuid,
        }
      }

      return { action: nil, auto_ran: false, forms: [] } if raw.empty?

      # Merge duplicates by merge_key. Count sums; payload takes the first.
      merged = raw
        .group_by { |p| p[:merge_key] }
        .map { |_key, group|
          first = group.first
          total_count = group.sum { |g| g[:count] }
          first.merge(count: total_count)
        }

      # ORDER matters, not just level. Prod 1201: "move it to Ours and let
      # Chelsea know" produced add_agenda_item (level 3, a checkbox) plus
      # message_partner (level 1, fires on arrival). Splitting purely on level
      # ran them backwards — Chelsea was told the event had moved 22 seconds
      # before the checkbox was tapped, and would have been told even if it
      # never was.
      #
      # So the calls become ordered STEPS (see build_steps). Everything up to and
      # including the first GATE — the first thing that has to finish before the
      # rest can honestly happen — goes out now; everything after it rides on
      # that gate and lands when it resolves (see advance_queue!). split_at_gate
      # leaves the gate as the last step of `head`, so it's the only step handed
      # anything to carry, and a level-2-only checklist never takes the queue.
      steps        = build_steps(merged)
      head, queue  = split_at_gate(steps)
      head         = runnable_now(user, byte_message.byte_conversation, head)
      queued       = serialize_steps(queue)
      gate         = (head.last if gate?(head.last))
      conversation = byte_message.byte_conversation

      auto_ran = false
      action   = nil
      posted   = []
      # Whether the queue found something to ride on. A gate that refuses to
      # materialize (every form's target gone, a countdown that won't start)
      # leaves nothing to advance it, so it runs below rather than being dropped.
      carried  = queued.empty?

      head.each { |step|
        deferred = (step.equal?(gate) ? queued : [])
        case step[:kind]
        when :autos
          auto_ran = run_auto(user, byte_message, step[:calls]) || auto_ran
        when :timer
          ran, holding = run_wait!(user, byte_message, step[:calls], deferred: deferred)
          auto_ran ||= ran
          carried  ||= holding
        when :relay
          asked, holding = run_ask!(user, byte_message, step[:calls], deferred: deferred)
          auto_ran ||= asked
          carried  ||= holding
        when :rows
          action = attach_checklist!(user, byte_message, step[:calls], deferred: deferred)
          carried ||= deferred.any?
        when :forms
          posted = post_forms(user, conversation, step[:calls], deferred: deferred)
          carried ||= deferred.any? && posted.any?
        end
      }

      run_steps!(user, conversation, byte_message, queued) unless carried

      { action: action, auto_ran: auto_ran, forms: posted }
    end

    # Re-materialize a proposal from an EXPIRED row so the person doesn't have to
    # re-type the request — tapping the stale checkbox reissues it as a fresh,
    # tappable checklist on a new message. Rebuilds through the normal `create`
    # path (re-validates + re-confirms), so the resolved data is refreshed and a
    # target that's since vanished degrades to an honest note.
    def reissue(user:, conversation:, button:)
      msg = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         "Here you go again:",
        metadata:     { "kind" => "buddy_reply", "source" => "reissue" },
        delivered_at: Time.current,
      )

      tool_name = button["tool_name"].to_s
      payload   = (button["payload"] || {}).symbolize_keys
      result    = create(user: user, byte_message: msg, markers: [{ tool_name: tool_name.to_sym, payload: payload }])

      if result[:action].nil? && !result[:auto_ran]
        msg.update!(body: "Hmm, I couldn't set that back up - what it pointed at might be gone now. Just ask me again?")
      end

      broadcast_message(user, msg.reload)
      result
    end

    # Run a set of markers with no model turn behind them: the Quick grid taps a
    # routine and its steps are already decided, so spending a round trip on
    # having the model re-say them costs money and introduces the one thing a
    # saved sequence exists to remove - a different answer each time.
    #
    # `body` is the line the steps hang under, since a checklist needs a message
    # to attach to and silence would read as nothing having happened.
    def run_markers!(user:, conversation:, markers:, body:)
      msg = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         body,
        metadata:     { "kind" => "buddy_reply", "source" => "quick_action" },
        delivered_at: Time.current,
      )

      result = create(user: user, byte_message: msg, markers: markers)
      # Every step dropped out - each one's target is gone, or the whole thing is
      # feature-gated away. Say so on the same message rather than leaving a
      # bare heading over nothing.
      if result[:action].nil? && !result[:auto_ran] && result[:forms].blank?
        msg.update!(body: "#{body}\n\nNothing in it could run just now - what it points at might be gone.")
      end

      broadcast_message(user, msg.reload)
      result
    end

    # Take the queue off the action so it can only ever run once. Called INSIDE
    # the caller's `with_lock` (before its `save!`), so two taps racing can't
    # both claim it; running the tools happens after the lock is released, since
    # they post messages and broadcast and have no business holding a row lock.
    def claim_deferred(action)
      input = action.tool_input.is_a?(Hash) ? action.tool_input : {}
      queue = Array(input["deferred"])
      return [] if queue.empty?

      action.tool_input = input.merge("deferred" => [], "deferred_claimed_at" => Time.current.iso8601)
      queue
    end

    # Is this timer a WAIT with the rest of a sequence lined up behind it?
    # Buddy::Timers asks before it words the alarm, so a pause Buddy took on its
    # own doesn't announce itself as a countdown that merely ran out.
    def waiting_on?(timer)
      timer_gate(timer).present?
    end

    # Release what the wait was holding. Called by Buddy::Timers the moment the
    # countdown fires. The queue is claimed under a lock, so a re-delivered fire
    # job can't run the follow-up twice.
    #
    # Nothing releases it early and nothing releases it if the timer is dismissed
    # before it rings — same escape hatch a checklist has, where walking away
    # mid-chain just leaves the rest unposted.
    def resume_after!(timer)
      action = timer_gate(timer)
      return false if action.nil?

      queue = nil
      action.with_lock do
        queue = claim_deferred(action)
        action.update!(state: :decided, decided_at: Time.current)
      end
      return false if queue.blank?

      advance_queue!(action, queue, executed: true)
    end

    # Is this relay a question a sequence is lined up behind? Buddy::CompanionRelay
    # asks before it does anything, so an ordinary question — the overwhelming
    # majority — costs one indexed lookup and nothing else.
    def awaiting_reply?(relay)
      relay_gate(relay).present?
    end

    # Release what the question was holding, now that they've answered. Called
    # the moment the answer is recorded, from the one funnel both ways of
    # answering pass through.
    #
    # Their answer becomes the gate's captured value, so the step behind it can
    # reference it. Claimed under a lock like every other release, so answering
    # twice can't run the follow-up twice.
    def resume_after_reply!(relay)
      action = relay_gate(relay)
      return false if action.nil?

      queue = nil
      var   = nil
      action.with_lock do
        var   = action.tool_input["var"].to_s.presence
        queue = claim_deferred(action)
        action.update!(state: :decided, decided_at: Time.current)
      end
      # Awaited, but with nothing lined up behind it. The promise was still made
      # out loud, so hand the answer to Buddy as a turn instead of letting it
      # land as a bubble nobody responds to.
      return pick_back_up!(action, relay) if queue.blank?

      captured = var ? { var => relay.answer } : {}
      advance_queue!(action, queue, executed: true, captured: captured)
    end

    # Buddy's turn on an answer it said it would come back to.
    #
    # The answer itself is already in the thread by now (record_answer! bridges
    # it before it gets here), so this is only the nudge to act on it — which is
    # the whole difference between "Chelsea said yes" sitting there and the
    # plunge actually going on the calendar.
    def pick_back_up!(action, relay)
      conversation = action.byte_conversation || Buddy::CompanionRelay.conversation_for(relay.from_user)
      return false if conversation.nil?

      Buddy::CompanionDelivery.deliver_prompt(
        user:         relay.from_user,
        conversation: conversation,
        seed:         answered_seed(relay),
        metadata:     {
          "kind"     => "buddy_trigger",
          "hidden"   => true,
          "source"   => "relay_answer",
          "relay_id" => relay.id,
        },
      )
      true
    rescue StandardError => e
      Buddy::Errors.report(section: "proposal_builder.pick_back_up", exception: e, user: relay.from_user)
      false
    end

    def answered_seed(relay)
      who    = relay.to_user&.first_name.presence || "They"
      answer = Array.wrap(relay.answer).map(&:to_s).compact_blank.join(", ").presence || "(no answer given)"

      <<~SEED.strip
        [nothing was said to you - #{who} just answered the question you were waiting on, and your reply is what happens next]

        You asked #{who}: "#{relay.body}"
        #{who} answered: #{answer}

        Their answer is already visible in the thread, so don't read it back to them. Do the thing the answer was FOR - put it on the calendar, pass it along, set the reminder, whatever you asked in order to find out - and say what you did in one short line. If the answer means there's nothing to do after all, say so warmly and stop.
      SEED
    end

    # Move the queue forward now that the gate it was waiting on has resolved.
    #
    # `executed:` is whether anything on that gate actually ran. When the person
    # cancelled it all, everything behind it is about something that never
    # happened, so it must NOT go out — but silence is how they end up assuming
    # it did, so say what was held back instead. A wait always passes true: the
    # clock can't decline.
    #
    # Level-1 steps fire and the queue keeps moving. The first step that puts
    # something in FRONT of the person — a checklist or a form — takes whatever
    # is still behind it and the queue stops there until they deal with it. That
    # is also the escape hatch: nothing advances on its own, so wandering off
    # mid-chain just leaves the rest of it unposted.
    # `captured` is whatever this gate LEARNED — a form's answers, a partner's
    # reply — folded onto the values already collected. Read off the action
    # rather than passed in by every caller, because the queue is what the
    # values belong to and the queue is already there.
    def advance_queue!(action, queue, executed:, captured: {})
      steps = rehydrate_steps(queue)
      return false if steps.empty?

      message = action.byte_message
      return false if message.nil?

      user         = action.user
      conversation = action.byte_conversation
      vars         = vars_on(action).merge(stringify(captured))

      unless executed
        note = "Held off on #{queue_summary(user, steps, vars)} — nothing on that list went through."
        post_message(user, conversation, note)
        return false
      end

      run_steps!(user, conversation, message, steps, vars)
    end

    # The gate is never going to resolve, so say what won't be happening and
    # throw the queue away. Same shape as the `executed: false` path in
    # advance_queue! — silence is how someone ends up assuming a sequence
    # finished, and this is the one case where nothing else will ever say so.
    def abandon_queue!(action, queue, because:)
      steps = rehydrate_steps(queue)
      return false if steps.empty?

      conversation = action.byte_conversation
      return false if conversation.nil?

      user = action.user
      post_message(
        user, conversation,
        "#{because}, so I didn't go on to #{queue_summary(user, steps, vars_on(action))}."
      )
    end

    # Values collected so far, as stored on whichever gate is holding the queue.
    def vars_on(action)
      input = action.tool_input.is_a?(Hash) ? action.tool_input : {}
      (input["vars"] || {}).to_h.transform_keys(&:to_s)
    end

    class << self
      private

      # The model's calls as ordered STEPS: each one a contiguous run of a single
      # kind, in the order the calls were made. That order is the only dependency
      # signal available and it's the right one, since "do X, then Y" is exactly
      # how a person phrases a sequence.
      #
      #   :autos — level 1. Fires the moment it's reached.
      #   :rows  — one checklist. A GATE when it holds anything level 3.
      #   :forms — one or more editable forms. Always a gate.
      #   :timer — a wait. Always a gate, and always alone, so "wait a minute,
      #            do X, wait five, do Y" nests instead of collapsing.
      #
      # Otherwise contiguous, not global, so the common batch still batches: two
      # agenda items asked for together stay two rows on one checklist, and three
      # prompts stay three forms posted side by side.
      def build_steps(merged)
        level2, rest = merged.partition { |p|
          p[:tool][:level] == 2 && Buddy::StepVars.references(p[:payload]).empty?
        }
        steps = rest.each_with_object([]) { |p, out|
          kind = step_kind(p)
          if SOLO_KINDS.exclude?(kind) && out.last && out.last[:kind] == kind
            out.last[:calls] << p
          else
            out << { kind: kind, calls: [p] }
          end
        }
        return steps if level2.empty?

        # Level 2 executes the instant it arrives, so it can never sit in a
        # queue. It joins the first checklist when that checklist is also the
        # first gate; otherwise it gets one of its own out front, which isn't a
        # gate and so holds nothing up behind it.
        #
        # Unless it's waiting on a value. Hoisting is a reordering, and it's
        # harmless right up until a step's arguments depend on something an
        # earlier gate collects: `ask_me` then `log_event("{{mine}}")` logged an
        # event literally named "{{mine}}" before the question was even asked.
        # Those stay where they were put and ride the queue like anything else —
        # they run a moment later than usual, which is the whole point.
        gate_idx = steps.index { |s| gate?(s) }
        rows_idx = steps.index { |s| s[:kind] == :rows }
        if rows_idx && rows_idx == gate_idx
          steps[rows_idx][:calls] = level2 + steps[rows_idx][:calls]
        else
          steps.unshift({ kind: :rows, calls: level2 })
        end
        steps
      end

      def step_kind(proposal)
        return :timer if Buddy::Tools.waits?(proposal[:tool], proposal[:payload])
        return :relay if Buddy::Tools.awaits_reply?(proposal[:tool], proposal[:payload])
        return :forms if Buddy::Tools.form?(proposal[:tool])

        proposal[:tool][:level] == 1 ? :autos : :rows
      end

      # A gate is anything that has to finish before whatever follows it can
      # honestly happen — usually the person, sometimes just the clock. A
      # checklist of already-executed level-2 rows is neither: nobody has to
      # touch it, so nothing may wait on it.
      def gate?(step)
        return false if step.nil?
        return true if [:forms, :timer, :relay].include?(step[:kind])

        step[:kind] == :rows && step[:calls].any? { |p| p[:tool][:level] == 3 }
      end

      def split_at_gate(steps)
        idx = steps.index { |s| gate?(s) }
        return [steps, []] if idx.nil?

        [steps[..idx], steps[(idx + 1)..] || []]
      end

      # What a gate stores: the queue it's holding, plus the values collected so
      # far on the way here. `vars` travels with the queue rather than living
      # anywhere of its own, so it survives however many gates the tail crosses
      # and is thrown away with the queue when the sequence ends.
      #
      # Both keys are omitted when empty so a gate holding nothing keeps the
      # `{}` tool_input it has always had.
      def gate_input(deferred, vars)
        input = {}
        input["deferred"] = deferred if deferred.present?
        input["vars"] = stringify(vars) if vars.present?
        input
      end

      # Build the checklist onto `byte_message` and return its ByteAction. We
      # don't use ByteAction.create_request! because that spawns a NEW inbound
      # "action-request" bubble — we want the rows under the message we were
      # given. Level-2 rows run their tool right here so they arrive already
      # executed (and undoable); level-3 rows stay pending.
      #
      # Tool label procs may return a plain String (title only) or a Hash
      # `{ title:, sub: }` — the second renders `sub` as small text beneath the
      # title, so non-default details (a past completion time, an assignee that
      # isn't the person, extra function args) don't crowd the title line.
      def attach_checklist!(user, byte_message, calls, deferred: [], vars: {})
        conversation = byte_message.byte_conversation
        buttons = calls.each_with_index.map { |p, i|
          base = build_button(user, p, i + 1)
          p[:tool][:level] == 2 ? run_level2_row(user, conversation, p, base) : base.merge("status" => "pending")
        }

        action = ByteAction.create!(
          user:              user,
          byte_conversation: conversation,
          byte_message:      byte_message,
          kind:              :custom,
          tool_name:         "buddy_proposals",
          multi_select:      true,
          buttons:           buttons,
          # Whatever the model lined up behind this, waiting on the tap.
          tool_input:        gate_input(deferred, vars),
          # A Buddy checklist is part of the conversation, not a fleeting prompt —
          # the default 10-minute TTL made a chore-confirm checkbox silently 409 on
          # tap (the check just vanished) once the person came back to it. Give it
          # a generous window so tapping later still works.
          expires_at:        PROPOSAL_TTL.from_now,
        )

        # Anything earlier in the thread that these rows replace is done with —
        # a correction shouldn't leave both versions sitting there.
        Buddy::Supersede.replace!(action: action, keys: buttons.pluck("merge_key"))

        # Mirror the action into the message metadata so the client picks it up on
        # hydrate + render. `kind: buddy_reply` opts the message into markdown
        # body rendering + attaches the checklist under the body.
        byte_message.update!(metadata: (byte_message.metadata || {}).merge(
          "kind"              => "buddy_reply",
          "tool_name"         => "buddy_proposals",
          "action_request_id" => action.request_id,
          "action_kind"       => "custom",
          "action_state"      => "pending",
          "action_expires_at" => action.expires_at&.iso8601, # so the client can grey out stale rows
          "multi_select"      => true,
          "buttons"           => buttons,
        ))
        action
      end

      # The bubble a queued checklist hangs under. Deliberately a bare lead-in:
      # the rows below it say what they are, and composing a real sentence here
      # would mean spending a whole model turn the person didn't ask for.
      def next_step_message(user, conversation)
        msg = conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         "Next up:",
          metadata:     { "kind" => "buddy_reply", "source" => "queued_step" },
          delivered_at: Time.current,
        )
        broadcast_message(user, msg)
        msg
      end

      # Consume steps in order until one of them lands in FRONT of the person;
      # that one takes whatever is left and the queue stops there. Level-1 steps
      # just run and the walk continues. Returns whether anything happened.
      def run_steps!(user, conversation, message, steps, vars={})
        ran = false
        while (step = steps.shift)
          calls, broken = rehydrate_calls(step, vars).partition { |p| p[:missing].blank? }
          report_missing_vars(user, conversation, broken) if broken.any?
          next if calls.empty?

          # `steps` is what's LEFT, still in its stored shape, so it rides along
          # untouched onto whatever this step posts — and `vars` with it, since
          # a value captured before this step is just as needed after it.
          case step["kind"].to_s
          when "forms"
            # A form that refuses to open posts nothing, so it can't carry the
            # queue either — keep walking instead of stranding it.
            return true if post_forms(user, conversation, calls, deferred: steps, vars: vars).any?
          when "rows"
            attach_checklist!(user, next_step_message(user, conversation), calls, deferred: steps, vars: vars)
            return true
          when "relay"
            # A question put to someone else. Same rule as the two above: if it
            # didn't actually go out there's nothing to answer it, so the rest
            # runs rather than waiting forever on a reply that can't come.
            asked, holding = run_ask!(user, message, calls, deferred: steps, vars: vars)
            return true if holding

            ran = asked || ran
          when "timer"
            # Same rule as a form that won't open: a countdown that fails to
            # start can't hold anything, so the rest runs rather than stalling.
            wait_ran, holding = run_wait!(user, message, calls, deferred: steps, vars: vars)
            return true if holding

            ran = wait_ran || ran
          else
            ran = run_auto(user, message, calls) || ran
          end
        end
        ran
      end

      # Nothing has been collected yet at the head of a sequence, so a step here
      # that references a value is asking for one that cannot exist. Say so and
      # drop it, rather than dispatching the literal `{{mine}}` at something
      # that will act on it.
      #
      # Reachable from a saved routine whose collecting step was deleted, or
      # markers built by hand. check_var_flow! stops it at save; this is the
      # backstop for everything that didn't come through there.
      def runnable_now(user, conversation, head)
        head.filter_map { |step|
          keep, broken = step[:calls].partition { |p| Buddy::StepVars.references(p[:payload]).empty? }
          next step if broken.empty?

          report_missing_vars(user, conversation, broken.map { |p| p.merge(missing: Buddy::StepVars.references(p[:payload])) })
          step.merge(calls: keep) if keep.any?
        }
      end

      # A step wanted a value nothing ever captured. Nearly always a routine
      # whose earlier step was edited out from under it, and the person has to
      # hear about it: silence here reads as the sequence having finished.
      def report_missing_vars(user, conversation, broken)
        names = broken.flat_map { |p| p[:missing] }.uniq
        steps = broken.map { |p| p[:tool][:name].to_s.tr("_", " ") }.uniq
        Rails.logger.warn("[Buddy::ProposalBuilder] unfilled step vars #{names.inspect} on #{steps.inspect}")
        post_message(
          user, conversation,
          "I skipped #{steps.to_sentence} — it needed #{names.map { |n| "`#{n}`" }.to_sentence}, " \
          "and nothing earlier in that sequence collected it."
        )
      end

      # Start the wait and park everything after it on the countdown. Returns
      # [whether the timer ran, whether it's now holding the queue].
      def run_wait!(user, byte_message, calls, deferred: [], vars: {})
        timer_id = nil
        ran = run_auto(user, byte_message, calls) { |result|
          data = result[:data]
          timer_id ||= data[:timer_id] if result[:ok] && data.is_a?(Hash)
        }

        holding = timer_id.present? && deferred.any?
        hold_for_timer!(user, byte_message, timer_id, deferred, vars) if holding
        [ran, holding]
      end

      # Put the question, then park everything after it on the ANSWER. Returns
      # [whether it went out, whether it's now holding the queue].
      #
      # The mirror of run_wait!, with one difference that matters: a countdown
      # always finishes, and a person doesn't. Everything queued behind this
      # waits on someone else deciding to reply, which is why the gate carries
      # its own expiry (see AWAIT_TTL) rather than trusting it to arrive.
      def run_ask!(user, byte_message, calls, deferred: [], vars: {})
        relay_id = nil
        var      = nil
        asked = run_auto(user, byte_message, calls) { |result|
          data = result[:data]
          next unless result[:ok] && data.is_a?(Hash) && relay_id.nil?

          relay_id = data[:relay_id]
          var      = data[:var]
        }

        # A gate goes up whenever the answer was AWAITED, not only when steps
        # are queued behind it. `await_reply` with nothing following is a
        # perfectly ordinary thing to ask for — "ask Chelsea if she wants to
        # plunge tomorrow" and then act on what she says — and the receipt
        # promises "I'll pick this back up when they answer" off the var alone.
        # Gating only on `deferred.any?` meant that promise was made and then
        # nothing existed to keep it: the answer came back as a bubble and Buddy
        # never took a turn on it. resume_after_reply! handles the empty queue.
        holding = relay_id.present? && (deferred.any? || var.present?)
        hold_for_reply!(user, byte_message, relay_id, var, deferred, vars) if holding
        [asked, holding]
      end

      def hold_for_reply!(user, byte_message, relay_id, var, deferred, vars)
        ByteAction.create!(
          user:              user,
          byte_conversation: byte_message.byte_conversation,
          byte_message:      byte_message,
          kind:              :custom,
          tool_name:         RELAY_GATE,
          buttons:           [],
          tool_input:        gate_input(deferred, vars).merge("relay_id" => relay_id, "var" => var),
          # Long, but finite. Someone who hasn't answered in three days isn't
          # going to, and a sequence that fires its last step a week later is
          # worse than one that admits it gave up.
          expires_at:        AWAIT_TTL.from_now,
        )
      end

      def relay_gate(relay)
        return nil if relay.nil?

        scope = ByteAction.where(user_id: relay.from_user_id, tool_name: RELAY_GATE, state: :pending)
        scope = scope.where("tool_input->>'relay_id' = ?", relay.id.to_s)
        scope.order(:id).last
      end

      def hold_for_timer!(user, byte_message, timer_id, deferred, vars)
        ByteAction.create!(
          user:              user,
          byte_conversation: byte_message.byte_conversation,
          byte_message:      byte_message,
          kind:              :custom,
          tool_name:         TIMER_GATE,
          buttons:           [],
          tool_input:        gate_input(deferred, vars).merge("timer_id" => timer_id),
          # Well past any countdown Buddy will set (Timers caps at 24h), so the
          # gate can never expire out from under a wait that's still running.
          expires_at:        PROPOSAL_TTL.from_now,
        )
      end

      def timer_gate(timer)
        return nil if timer.nil?

        scope = ByteAction.where(user_id: timer.user_id, tool_name: TIMER_GATE, state: :pending)
        scope = scope.where("tool_input->>'timer_id' = ?", timer.id.to_s)
        scope.order(:id).last
      end

      def post_forms(user, conversation, forms, deferred: [], vars: {})
        return [] if forms.empty?

        # Only ONE form carries the queue. Splitting it across a batch would mean
        # the follow-up fires when any of them is sent, which is the opposite of
        # waiting for the step to be finished. It goes to the first form that
        # actually lands, since a form whose target is gone posts nothing.
        queue = deferred
        forms.filter_map { |p|
          action = Buddy::FormAction.post!(
            user:         user,
            conversation: conversation,
            tool:         p[:tool],
            payload:      p[:payload],
            merge_key:    (p[:merge_key] if Buddy::Tools.supersedes?(p[:tool])),
            deferred:     queue,
            vars:         vars,
          )
          next nil if action.nil?

          queue = []
          action
        }
      end

      def serialize_steps(steps)
        steps.map { |step|
          {
            "kind"  => step[:kind].to_s,
            "calls" => step[:calls].map { |p|
              {
                "tool_name" => p[:tool][:name].to_s,
                "payload"   => stringify(p[:payload]),
                "count"     => p[:count] || 1,
                # Carried through so a step that posts later still replaces
                # whatever it's a corrected version of.
                "merge_key" => p[:merge_key],
              }
            },
          }
        }
      end

      def rehydrate_steps(queue)
        rows = Array(queue)
        return [] if rows.empty?
        # Actions posted before the queue understood steps stored a flat list of
        # level-1 calls. Read that shape as one autos step, so a checklist still
        # sitting in someone's thread keeps working.
        return [{ "kind" => "autos", "calls" => rows }] if rows.first.key?("tool_name")

        rows
      end

      # The one place a queued step's arguments are turned back into something
      # dispatchable, and so the one place `{{name}}` is filled in. A call whose
      # references can't be satisfied comes back carrying `missing` rather than
      # being dropped, because the caller has to SAY so - passing a literal
      # `{{hers}}` to a Jil task, or quietly skipping the step, are the two
      # failures worth more than the step itself.
      def rehydrate_calls(step, vars={})
        Array(step["calls"]).filter_map { |row|
          tool = Buddy::Tools[row["tool_name"].to_s.to_sym]
          next nil if tool.nil?

          payload, missing = Buddy::StepVars.fill((row["payload"] || {}).symbolize_keys, vars)
          {
            tool:      tool,
            payload:   payload,
            count:     (row["count"] || 1).to_i,
            merge_key: row["merge_key"],
            missing:   missing.presence,
          }.compact
        }
      end

      # "Message Chelsea", not "message partner" — the tool's own label proc
      # already renders its payload for a human, so reuse it rather than
      # humanizing a snake_case name at someone.
      def queue_summary(user, steps, vars={})
        ctx = Buddy::ToolContext.new(user)
        titles = steps.flat_map { |step| rehydrate_calls(step, vars) }.map { |p|
          title, = extract_title_sub(safely { p[:tool][:label].call(p[:payload], ctx) })
          title.presence || p[:tool][:name].to_s.tr("_", " ")
        }
        titles.uniq.to_sentence.presence || "the follow-up"
      end

      def post_message(user, conversation, body)
        msg = conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         body,
          metadata:     { "kind" => "buddy_reply", "source" => "deferred_skipped" },
          delivered_at: Time.current,
        )
        broadcast_message(user, msg)
        msg
      end

      def broadcast_message(user, message)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.as_wire },
        })
      end

      # Execute each auto (no-confirm) tool now and post a distinct activity
      # receipt chip for it. Returns true if any ran. Failures degrade to a
      # short "couldn't" chip rather than blowing up the whole reply.
      #
      # Yields each raw dispatch result, for the one caller that needs what the
      # tool returned rather than just that it went (see run_wait!).
      def run_auto(user, byte_message, autos)
        return false if autos.empty?

        conversation = byte_message.byte_conversation
        name = conversation.buddy_name

        autos.each do |p|
          # Feed execute the SAME payload shape the confirm path produces (top-
          # level symbol keys, values JSON-flattened so Times are ISO strings),
          # so a tool behaves identically whether it's auto or confirmed.
          payload = stringify(p[:payload]).symbolize_keys
          # A level-1 tool has no checklist row, but its receipt still reads
          # `ctx.proposal` for the resolved name. Passing the same shape
          # run_level2_row builds is what makes that work: without it every such
          # receipt raised NoMethodError on nil, got swallowed, and the chip was
          # skipped — so "turn the fan to high" ran with no visible record at all.
          proposal_shape = { "id" => nil, "payload" => stringify(p[:payload]), "tool_name" => p[:tool][:name].to_s }
          ctx = Buddy::ToolContext.new(user, proposal: proposal_shape, conversation: conversation)
          result = Buddy::Tools.dispatch(p[:tool], payload, ctx)
          yield(result) if block_given?
          text =
            if result[:ok]
              rc = receipt_for(p[:tool], result[:data], ctx)
              # nil is a deliberate opt-out: the tool puts its own result in
              # front of the person (list_reminders draws the rows), so there's
              # no chip to post. A receipt that RAISED is not an opt-out and
              # must still be seen.
              next if rc.nil?

              rc.presence || "Done"
            else
              Rails.logger.warn("[Buddy::ProposalBuilder] auto tool #{p[:tool][:name]} failed: #{result[:error]}")
              "#{name} couldn't do that one"
            end

          chip = conversation.byte_messages.create!(
            user:         user,
            direction:    :inbound,
            state:        :delivered,
            # The chip already carries a leading ✓ from CSS, and most receipts end
            # with one of their own — together they rendered "✓ Called Great Fan ✓".
            body:         text.sub(/\s*[✓✔]\s*\z/, ""),
            metadata:     {
              "kind"      => "buddy_activity",
              "tool_name" => p[:tool][:name].to_s,
              "ok"        => result[:ok],
              # Rendered as its own quiet sub-line rather than jammed into the
              # body, so it reads as a footnote instead of competing with the
              # receipt above it.
              "detail"    => activity_detail(p[:tool], payload, ctx),
              # The exact arguments it ran with, for when the chip text isn't
              # enough to answer "what did it actually do".
              "payload"   => stringify(p[:payload]),
              # Pre-resolution arguments, for Buddy::Routines.capture.
              "args"      => stringify(p[:args] || p[:payload]),
            },
            delivered_at: Time.current,
          )
          MonitorChannel.broadcast_to(user, {
            id:      :byte,
            channel: :byte,
            data:    { kind: :message, message: chip.as_wire },
          })
        end
        true
      end

      # A receipt that returns nil OPTED OUT; a receipt that raises did not, and
      # swallowing the difference is how a tool ran with nothing to show for it.
      # A crash falls back to the tool's own name so the chip still posts.
      def receipt_for(tool, data, ctx)
        tool[:receipt].call(data, ctx)
      rescue StandardError => e
        Rails.logger.warn("[Buddy::ProposalBuilder] #{tool[:name]} receipt raised: #{e.class}: #{e.message}")
        "Ran #{tool[:name].to_s.tr("_", " ")}"
      end

      # The second line of an activity chip: the arguments the action ran with. A
      # level-1 action leaves no checklist row behind, so without this the only
      # trace is prose the model wrote — and prose is exactly what we can't take
      # at face value. Reuses the tool's own label proc, which already formats
      # its params for the checklist.
      #
      # The internal tool name used to lead this line, but `call_jil_function`
      # means nothing to someone reading a receipt, and the line above already
      # says WHAT ran. It stays on the message metadata, where debugging can
      # reach it without putting snake_case in front of a person. Argument keys
      # get their underscores turned back into spaces for the same reason.
      def activity_detail(tool, payload, ctx)
        raw = safely { tool[:label].call(payload, ctx) }
        sub = raw.is_a?(Hash) ? (raw[:sub] || raw["sub"]).to_s.presence : nil
        return nil if sub.blank?

        sub.split("\n").map { |line|
          key, value = line.split(":", 2)
          value ? "#{key.to_s.strip.tr("_", " ")}: #{value.strip}" : line.strip
        }.join(" · ")
      end

      # The shared "row shell" both level-2 and level-3 rows start from: id,
      # label/sublabel (from the tool's label or merge_label proc), tool name,
      # payload, and count. Status/result get layered on after.
      def build_button(user, p, id)
        ctx = Buddy::ToolContext.new(user)
        raw = safely {
          if p[:count] > 1 && p[:tool][:merge_label]
            p[:tool][:merge_label].call(p[:payload], p[:count])
          else
            p[:tool][:label].call(p[:payload], ctx)
          end
        } || p[:tool][:name].to_s

        title, sub = extract_title_sub(raw)
        # A label proc can return a blank title (e.g. a name resolved to ""),
        # which renders as an unreadable empty checkbox row. Never allow that —
        # fall back to a humanized tool name so every row says SOMETHING.
        title = p[:tool][:name].to_s.tr("_", " ") if title.to_s.strip.empty?
        {
          "id"        => id,
          "label"     => title,
          "sublabel"  => sub,
          "tool_name" => p[:tool][:name].to_s,
          "payload"   => stringify(p[:payload]),
          # Pre-resolution arguments, for Buddy::Routines.capture.
          "args"      => stringify(p[:args] || p[:payload]),
          "count"     => p[:count],
          # What makes two calls "the same thing", but ONLY for the tools where
          # asking again means correcting. A repeatable action (a second glass of
          # water) carries no key, so nothing can ever retire it.
          "merge_key" => (p[:merge_key] if Buddy::Tools.supersedes?(p[:tool])),
        }
      end

      # Execute a level-2 row immediately (count times) and return its button
      # already resolved: `executed` + a revert descriptor makes it `undoable`,
      # so the client renders it pre-checked and unchecking it walks the action
      # back. Mirrors the per-row execution in ProposalExecutor, minus the
      # separate receipt bubble (the pre-checked row IS the receipt).
      def run_level2_row(user, conversation, p, base)
        tool = p[:tool]
        proposal_shape = { "id" => base["id"], "payload" => base["payload"], "tool_name" => base["tool_name"] }
        ctx = Buddy::ToolContext.new(user, proposal: proposal_shape, conversation: conversation)
        payload = base["payload"].symbolize_keys
        count = (base["count"] || 1).to_i

        outcomes = Array.new(count) { Buddy::Tools.dispatch(tool, payload, ctx) }

        if outcomes.all? { |o| o[:ok] }
          data    = outcomes.first[:data].is_a?(Hash) ? outcomes.first[:data] : {}
          reverts = outcomes.filter_map { |o| o[:data].is_a?(Hash) ? (o[:data][:revert] || o[:data]["revert"]) : nil }
          base.merge(
            "status"   => "executed",
            "result"   => stringify(data).merge("reverts" => reverts),
            "receipt"  => safely { tool[:receipt].call(outcomes.first[:data], ctx) }.to_s,
            "undoable" => reverts.any?,
          )
        elsif outcomes.any? { |o| o[:ok] }
          base.merge("status" => "partial", "error_message" => outcomes.reject { |o| o[:ok] }.pick(:error))
        else
          base.merge("status" => "failed", "error_message" => outcomes.first[:error])
        end
      end

      def extract_title_sub(raw)
        if raw.is_a?(Hash)
          title = (raw[:title] || raw["title"]).to_s
          sub   = (raw[:sub] || raw["sub"]).to_s.presence
          [title, sub]
        else
          [raw.to_s, nil]
        end
      end

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), out|
          out[k.to_s] = v.is_a?(Time) ? v.iso8601 : v
        }
      end

      def safely
        yield
      rescue StandardError => e
        Rails.logger.warn("[Buddy::ProposalBuilder] proc raised: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
