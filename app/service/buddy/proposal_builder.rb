module Buddy
  # Takes the raw markers from Buddy::MarkerParser, validates them against
  # the tool registry, dedups/merges by tool.merge_key, and attaches ONE
  # ByteAction (multi_select: true) to the given Buddy reply message.
  # Each button row in the action carries { id, label, tool_name, payload,
  # status: "pending", count } — everything the executor needs to run and
  # everything the client needs to render.
  module ProposalBuilder
    module_function

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

        ctx = Buddy::ToolContext.new(user)
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

      # Trusted, no-confirm tools execute immediately and drop an activity
      # receipt; everything else becomes a checkbox row awaiting confirmation.
      auto, confirm = merged.partition { |p| p[:tool][:auto] }
      auto_ran = run_auto(user, byte_message, auto)

      return { action: nil, auto_ran: auto_ran } if confirm.empty?

      # Build button hashes. Tool label procs may return either a plain
      # String (title only) or a Hash `{ title:, sub: }` — the second form
      # renders the `sub` value as small text beneath the title so
      # non-default details (a past completion time, an assignee that isn't
      # the current user, extra function args being passed) don't have to
      # crowd the title line.
      buttons = confirm.each_with_index.map { |p, i|
        ctx = Buddy::ToolContext.new(user)
        raw = safely {
          if p[:count] > 1 && p[:tool][:merge_label]
            p[:tool][:merge_label].call(p[:payload], p[:count])
          else
            p[:tool][:label].call(p[:payload], ctx)
          end
        } || p[:tool][:name].to_s

        title, sub = extract_title_sub(raw)

        {
          "id"        => i + 1,
          "label"     => title,
          "sublabel"  => sub,
          "tool_name" => p[:tool][:name].to_s,
          "payload"   => stringify(p[:payload]),
          "count"     => p[:count],
          "status"    => "pending",
        }
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
        "multi_select"      => true,
        "buttons"           => buttons,
      )
      byte_message.update!(metadata: new_meta)

      { action: action, auto_ran: auto_ran }
    end

    class << self
      private

      # Execute each auto (no-confirm) tool now and post a distinct activity
      # receipt chip for it. Returns true if any ran. Failures degrade to a
      # short "couldn't" chip rather than blowing up the whole reply.
      def run_auto(user, byte_message, autos)
        return false if autos.empty?

        conversation = byte_message.byte_conversation
        name = user.buddy_theme.to_s == "moss" ? "Moss" : "Byte"

        autos.each do |p|
          ctx = Buddy::ToolContext.new(user)
          # Feed execute the SAME payload shape the confirm path produces (top-
          # level symbol keys, values JSON-flattened so Times are ISO strings),
          # so a tool behaves identically whether it's auto or confirmed.
          payload = stringify(p[:payload]).symbolize_keys
          result  = Buddy::Tools.dispatch(p[:tool], payload, ctx)
          text   =
            if result[:ok]
              safely { p[:tool][:receipt].call(result[:data], ctx) }.presence || "Done"
            else
              Rails.logger.warn("[Buddy::ProposalBuilder] auto tool #{p[:tool][:name]} failed: #{result[:error]}")
              "#{name} couldn't do that one"
            end

          chip = conversation.byte_messages.create!(
            user:         user,
            direction:    :inbound,
            state:        :delivered,
            body:         text,
            metadata:     { "kind" => "buddy_activity", "tool_name" => p[:tool][:name].to_s, "ok" => result[:ok] },
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
      rescue => e
        Rails.logger.warn("[Buddy::ProposalBuilder] proc raised: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
