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

      # Split by confidence level:
      #   1 → fire now + activity receipt chip (no checkbox).
      #   2 → fire now, but show up as a PRE-CHECKED checklist row the person
      #       can uncheck to undo.
      #   3 → a plain pending checkbox they tap to run.
      # Level-2 rows lead the checklist so the already-done items sit on top.
      # Form tools own their whole message (Buddy::FormAction), so they're taken
      # out before anything is split into rows — a checkbox that says "submit
      # these seven values" without showing them is exactly what the form
      # replaces.
      forms, merged  = merged.partition { |p| Buddy::Tools.form?(p[:tool]) }
      _, rest        = merged.partition { |p| p[:tool][:level] == 1 }
      level2, level3 = rest.partition { |p| p[:tool][:level] == 2 }

      # ORDER matters, not just level. Prod 1201: "move it to Ours and let
      # Chelsea know" produced add_agenda_item (level 3, a checkbox) plus
      # message_partner (level 1, fires on arrival). Splitting purely on level
      # ran them backwards — Chelsea was told the event had moved 22 seconds
      # before the checkbox was tapped, and would have been told even if it
      # never was.
      #
      # So a level-3 row is a GATE: level-1 calls the model made BEFORE it run
      # now, and ones it made AFTER wait on the tap (see run_deferred!). Level 2
      # is not a gate — it executes on arrival and leaves a visible row in the
      # same list, so nothing lands out of order behind it.
      immediate, deferred = split_on_gate(merged, gated: forms.any?)
      auto_ran = run_auto(user, byte_message, immediate)

      rows = level2 + level3
      # A form is a gate too, so anything held back rides on it when there's no
      # checklist to carry it. With both, the checklist takes the queue — it's
      # the one the person meets first.
      posted = post_forms(user, byte_message, forms, deferred: rows.empty? ? deferred : [])

      if rows.empty?
        return { action: nil, auto_ran: auto_ran, forms: posted }
      end

      # Build button hashes. Tool label procs may return either a plain
      # String (title only) or a Hash `{ title:, sub: }` — the second form
      # renders the `sub` value as small text beneath the title so
      # non-default details (a past completion time, an assignee that isn't
      # the current user, extra function args being passed) don't have to
      # crowd the title line. Level-2 rows run their tool right here so they
      # arrive already executed (and undoable); level-3 rows stay pending.
      conversation = byte_message.byte_conversation
      buttons = rows.each_with_index.map { |p, i|
        base = build_button(user, p, i + 1)
        p[:tool][:level] == 2 ? run_level2_row(user, conversation, p, base) : base.merge("status" => "pending")
      }

      # Attach a ByteAction to the reply message in-place. We don't use
      # ByteAction.create_request! because that spawns a NEW inbound
      # "action-request" bubble — we want the checklist right under Buddy's
      # reply, not as a separate message.
      action = ByteAction.create!(
        user:              user,
        byte_conversation: byte_message.byte_conversation,
        byte_message:      byte_message,
        kind:              :custom,
        tool_name:         "buddy_proposals",
        multi_select:      true,
        buttons:           buttons,
        # Anything the model queued behind the checkbox, waiting on the tap.
        tool_input:        deferred.any? ? { "deferred" => serialize_deferred(deferred) } : {},
        # A Buddy checklist is part of the conversation, not a fleeting prompt —
        # the default 10-minute TTL made a chore-confirm checkbox silently 409 on
        # tap (the check just vanished) once the person came back to it. Give it
        # a generous window so tapping later still works.
        expires_at:        PROPOSAL_TTL.from_now,
      )

      # Mirror the action into the message metadata so the client picks it
      # up on hydrate + render. `kind: buddy_reply` opts the message into
      # markdown body rendering + attaches the checklist under the body.
      new_meta = (byte_message.metadata || {}).merge(
        "kind"              => "buddy_reply",
        "tool_name"         => "buddy_proposals",
        "action_request_id" => action.request_id,
        "action_kind"       => "custom",
        "action_state"      => "pending",
        "action_expires_at" => action.expires_at&.iso8601,  # so the client can grey out stale rows
        "multi_select"      => true,
        "buttons"           => buttons,
      )
      byte_message.update!(metadata: new_meta)

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

    # Run what was waiting on the tap.
    #
    # `executed:` is whether anything on the checklist actually ran. When the
    # person cancelled it all, the follow-up is about something that never
    # happened, so it must NOT go out — but silence is how they end up assuming
    # it did, so say what was held back instead.
    def run_deferred!(action, queue, executed:)
      return false if queue.blank?

      message = action.byte_message
      return false if message.nil?

      unless executed
        note = "Held off on #{deferred_summary(action.user, queue)} — nothing on that list went through."
        post_message(action.user, message.byte_conversation, note)
        return false
      end

      autos = queue.filter_map { |row| rehydrate_deferred(row) }
      return false if autos.empty?

      run_auto(action.user, message, autos)
    end

    class << self
      private

      # Level-1 calls, partitioned on where they sit relative to the first
      # level-3 row. `merged` is in the model's own call order (filter_map then
      # group_by both preserve it), which is the only dependency signal we get —
      # and the right one, since "do X and then tell them" is exactly how a
      # person phrases a sequence.
      def split_on_gate(merged, gated: false)
        gate_at   = merged.index { |p| p[:tool][:level] == 3 }
        immediate = []
        deferred  = []
        merged.each_with_index { |p, i|
          next unless p[:tool][:level] == 1

          # `gated:` covers a form that was already lifted out of `merged` — it
          # is a gate as much as a checkbox is, so nothing queued alongside it
          # should fire before it's sent.
          (gated || (gate_at && i > gate_at) ? deferred : immediate) << p
        }
        [immediate, deferred]
      end

      def post_forms(user, byte_message, forms, deferred: [])
        return [] if forms.empty?

        conversation = byte_message.byte_conversation
        forms.each_with_index.filter_map { |p, i|
          Buddy::FormAction.post!(
            user:         user,
            conversation: conversation,
            tool:         p[:tool],
            payload:      p[:payload],
            # Only the first form carries the queue; two forms in one turn is
            # already unusual and splitting the queue between them would mean
            # the follow-up fires when either is sent.
            deferred:     i.zero? ? serialize_deferred(deferred) : [],
          )
        }
      end

      def serialize_deferred(deferred)
        deferred.map { |p|
          { "tool_name" => p[:tool][:name].to_s, "payload" => stringify(p[:payload]), "count" => p[:count] || 1 }
        }
      end

      def rehydrate_deferred(row)
        tool = Buddy::Tools[row["tool_name"].to_s.to_sym]
        return nil if tool.nil?

        { tool: tool, payload: (row["payload"] || {}).symbolize_keys, count: (row["count"] || 1).to_i }
      end

      # "Message Chelsea", not "message partner" — the tool's own label proc
      # already renders its payload for a human, so reuse it rather than
      # humanizing a snake_case name at someone.
      def deferred_summary(user, queue)
        ctx = Buddy::ToolContext.new(user)
        titles = queue.filter_map { |row|
          p = rehydrate_deferred(row)
          next nil if p.nil?

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
