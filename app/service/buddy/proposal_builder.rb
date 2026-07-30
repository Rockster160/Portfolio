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

    # Returns { action: <ByteAction or nil>, auto_ran: <bool> } so the caller
    # can pick the right expression: something to confirm (action present) vs
    # something already done (auto_ran) vs nothing.
    def create(user:, byte_message:, markers:)
      return { action: nil, auto_ran: false, forms: [] } if markers.blank?

      # Build validated per-marker proposals.
      raw = markers.filter_map { |m|
        tool = Buddy::Tools[m[:tool_name]]
        next nil if tool.nil?

        payload, errors = Buddy::Tools.validate_payload(tool, m[:payload])
        next nil if errors.any?

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
      # including the first GATE — the first thing that needs the person — goes
      # out now; everything after it rides on that gate and lands when they
      # resolve it (see advance_queue!).
      steps       = build_steps(merged)
      head, queue = split_at_gate(steps)

      auto_ran  = false
      rows_step = nil
      form_step = nil
      head.each { |step|
        case step[:kind]
        when :autos then auto_ran = run_auto(user, byte_message, step[:calls]) || auto_ran
        when :rows  then rows_step = step
        when :forms then form_step = step
        end
      }

      # The queue rides on whichever gate the person meets FIRST. `head` holds at
      # most one gate and it's the last step in it, so a checklist that is a gate
      # takes the queue and a level-2-only checklist never does.
      conversation = byte_message.byte_conversation
      queued       = serialize_steps(queue)
      on_rows      = gate?(rows_step)
      posted       = post_forms(user, conversation, form_step&.fetch(:calls, []) || [], deferred: on_rows ? [] : queued)
      action       = rows_step && attach_checklist!(user, byte_message, rows_step[:calls], deferred: on_rows ? queued : [])

      # The form gate was meant to carry the queue and every form refused to open
      # (a prompt answered somewhere else, say). Nothing is left to advance it, so
      # run it now rather than dropping it on the floor.
      run_steps!(user, conversation, byte_message, queued) if queued.any? && !on_rows && posted.empty?

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

    # Move the queue forward now that the gate it was waiting on has resolved.
    #
    # `executed:` is whether anything on that gate actually ran. When the person
    # cancelled it all, everything behind it is about something that never
    # happened, so it must NOT go out — but silence is how they end up assuming
    # it did, so say what was held back instead.
    #
    # Level-1 steps fire and the queue keeps moving. The first step that puts
    # something in FRONT of the person — a checklist or a form — takes whatever
    # is still behind it and the queue stops there until they deal with it. That
    # is also the escape hatch: nothing advances on its own, so wandering off
    # mid-chain just leaves the rest of it unposted.
    def advance_queue!(action, queue, executed:)
      steps = rehydrate_steps(queue)
      return false if steps.empty?

      message = action.byte_message
      return false if message.nil?

      user         = action.user
      conversation = action.byte_conversation

      unless executed
        note = "Held off on #{queue_summary(user, steps)} — nothing on that list went through."
        post_message(user, conversation, note)
        return false
      end

      run_steps!(user, conversation, message, steps)
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
      #
      # Contiguous, not global, so the common batch still batches: two agenda
      # items asked for together stay two rows on one checklist, and three
      # prompts stay three forms posted side by side.
      def build_steps(merged)
        level2, rest = merged.partition { |p| p[:tool][:level] == 2 }
        steps = rest.each_with_object([]) { |p, out|
          kind = step_kind(p)
          out.last && out.last[:kind] == kind ? out.last[:calls] << p : out << { kind: kind, calls: [p] }
        }
        return steps if level2.empty?

        # Level 2 executes the instant it arrives, so it can never sit in a
        # queue. It joins the first checklist when that checklist is also the
        # first gate; otherwise it gets one of its own out front, which isn't a
        # gate and so holds nothing up behind it.
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
        return :forms if Buddy::Tools.form?(proposal[:tool])

        proposal[:tool][:level] == 1 ? :autos : :rows
      end

      # A gate is anything that needs the person before whatever follows it can
      # honestly happen. A checklist of already-executed level-2 rows doesn't
      # qualify: nobody has to touch it, so nothing may wait on it.
      def gate?(step)
        return false if step.nil?
        return true if step[:kind] == :forms

        step[:kind] == :rows && step[:calls].any? { |p| p[:tool][:level] == 3 }
      end

      def split_at_gate(steps)
        idx = steps.index { |s| gate?(s) }
        return [steps, []] if idx.nil?

        [steps[..idx], steps[(idx + 1)..] || []]
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
      def attach_checklist!(user, byte_message, calls, deferred: [])
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
          tool_input:        deferred.any? ? { "deferred" => deferred } : {},
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
      def run_steps!(user, conversation, message, steps)
        ran = false
        while (step = steps.shift)
          calls = rehydrate_calls(step)
          next if calls.empty?

          # `steps` is what's LEFT, still in its stored shape, so it rides along
          # untouched onto whatever this step posts.
          case step["kind"].to_s
          when "forms"
            # A form that refuses to open posts nothing, so it can't carry the
            # queue either — keep walking instead of stranding it.
            return true if post_forms(user, conversation, calls, deferred: steps).any?
          when "rows"
            attach_checklist!(user, next_step_message(user, conversation), calls, deferred: steps)
            return true
          else
            ran = run_auto(user, message, calls) || ran
          end
        end
        ran
      end

      def post_forms(user, conversation, forms, deferred: [])
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

      def rehydrate_calls(step)
        Array(step["calls"]).filter_map { |row|
          tool = Buddy::Tools[row["tool_name"].to_s.to_sym]
          next nil if tool.nil?

          {
            tool:      tool,
            payload:   (row["payload"] || {}).symbolize_keys,
            count:     (row["count"] || 1).to_i,
            merge_key: row["merge_key"],
          }
        }
      end

      # "Message Chelsea", not "message partner" — the tool's own label proc
      # already renders its payload for a human, so reuse it rather than
      # humanizing a snake_case name at someone.
      def queue_summary(user, steps)
        ctx = Buddy::ToolContext.new(user)
        titles = steps.flat_map { |step| rehydrate_calls(step) }.map { |p|
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
          text =
            if result[:ok]
              rc = receipt_for(p[:tool], result[:data], ctx)
              # nil is a deliberate opt-out: the tool relays its own result via a
              # follow-up Buddy turn (check_weather), so there's no chip to post.
              # A receipt that RAISED is not an opt-out and must still be seen.
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
