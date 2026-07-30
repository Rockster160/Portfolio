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
      return { action: nil, auto_ran: false } if markers.blank?

      # Build validated per-marker proposals.
      raw = markers.filter_map { |m|
        tool = Buddy::Tools[m[:tool_name]]
        next nil if tool.nil?

        payload, errors = Buddy::Tools.validate_payload(tool, m[:payload])
        next nil if errors.any?

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

      return { action: nil, auto_ran: false } if raw.empty?

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
      level1, rest   = merged.partition { |p| p[:tool][:level] == 1 }
      level2, level3 = rest.partition { |p| p[:tool][:level] == 2 }
      auto_ran = run_auto(user, byte_message, level1)

      rows = level2 + level3
      return { action: nil, auto_ran: auto_ran } if rows.empty?

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
        tool_input:        {},
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

      { action: action, auto_ran: auto_ran }
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

    class << self
      private

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
