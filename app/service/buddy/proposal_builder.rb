module Buddy
  # Takes the raw markers from Buddy::MarkerParser, validates them against
  # the tool registry, dedups/merges by tool.merge_key, and attaches ONE
  # ByteAction (multi_select: true) to the given Buddy reply message.
  # Each button row in the action carries { id, label, tool_name, payload,
  # status: "pending", count } — everything the executor needs to run and
  # everything the client needs to render.
  module ProposalBuilder
    module_function

    def create(user:, byte_message:, markers:)
      return nil if markers.blank?

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

      return nil if raw.empty?

      # Merge duplicates by merge_key. Count sums; payload takes the first.
      merged = raw
        .group_by { |p| p[:merge_key] }
        .map { |_key, group|
          first = group.first
          total_count = group.sum { |g| g[:count] }
          first.merge(count: total_count)
        }

      # Build button hashes. Tool label procs may return either a plain
      # String (title only) or a Hash `{ title:, sub: }` — the second form
      # renders the `sub` value as small text beneath the title so
      # non-default details (a past completion time, an assignee that isn't
      # the current user, extra function args being passed) don't have to
      # crowd the title line.
      buttons = merged.each_with_index.map { |p, i|
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

      action
    end

    class << self
      private

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
