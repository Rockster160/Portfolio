module Buddy
  # An editable form posted into a Byte conversation, and the submit that runs
  # the tool behind it.
  #
  # The third shape of Byte action, after the proposal checklist and the manage
  # list. A checkbox can only say yes to what Buddy already decided; a form lets
  # Buddy fill in its best guess and hands the person every value to correct
  # before anything happens. That is what makes guessing safe, and guessing is
  # what makes a multi-field prompt answerable in one exchange instead of four.
  #
  # Lives on its OWN message rather than under Buddy's reply, because a message
  # carries a single `action_request_id` and a turn can produce both a checklist
  # and a form. Same reasoning ReminderList used.
  #
  # The client contract is the message metadata (see ByteMessage#as_wire); the
  # ByteAction stores what the SERVER needs to re-derive the form on submit —
  # deliberately not the posted fields, since a form that validates itself
  # against the copy the browser sent back validates nothing.
  module FormAction
    module_function

    TOOL_NAME = "buddy_form".freeze

    # Long, for the same reason a proposal checklist is: this sits in the thread
    # and someone may come back to it. The 10-minute ByteAction default is tuned
    # for a Claude hook blocking on a decision, and made checkboxes silently 409.
    TTL = 3.days

    # Build the form and post it. Returns the ByteAction, or nil when the tool
    # can't produce one (its `fields` proc is also its resolver — a prompt that
    # has since been answered raises there rather than posting an empty form).
    def post!(user:, conversation:, tool:, payload:, deferred: [])
      spec = tool[:form]
      return nil if spec.nil?

      ctx    = Buddy::ToolContext.new(user, conversation: conversation)
      fields = Buddy::FormFields.normalize(spec[:fields].call(payload, ctx))
      return nil if fields.empty?

      title   = call_or_value(spec[:title], payload, ctx).to_s.presence || tool[:name].to_s.tr("_", " ")
      message = post_message(user, conversation, title)

      action = ByteAction.create!(
        user:              user,
        byte_conversation: conversation,
        byte_message:      message,
        kind:              :custom,
        tool_name:         TOOL_NAME,
        multi_select:      false,
        buttons:           fields.map { |f| f.transform_keys(&:to_s) },
        tool_input:        {
          "tool_name" => tool[:name].to_s,
          "payload"   => stringify(payload),
          "deferred"  => deferred,
        },
        expires_at:        TTL.from_now,
      )

      message.update!(metadata: message.metadata.merge(wire(action, fields, spec)))
      broadcast(user, message.reload)
      action
    rescue StandardError => e
      Buddy::Errors.report(section: "form_action.post", exception: e, user: user)
      nil
    end

    # Run the tool with what the person actually sent.
    #
    # Returns { ok:, errors: } — errors render under the form so they can fix and
    # resend rather than losing what they typed.
    def submit!(action, values:)
      return { ok: false, errors: ["That form's already been sent."] } unless action.pending?
      return { ok: false, errors: ["That form has expired."] } if action.expires_at&.past?

      tool = Buddy::Tools[action.tool_input["tool_name"].to_s.to_sym]
      return { ok: false, errors: ["I can't run that one anymore."] } if tool.nil?

      user     = action.user
      deferred = []
      outcome  = nil

      action.with_lock do
        # Re-read inside the lock so a double-tap can't run the tool twice.
        action.reload
        next unless action.pending?

        outcome = run(action, tool, values, user)
        if outcome[:ok]
          action.state      = :decided
          action.decided_at = Time.current
          action.decision   = { "value" => outcome[:collected], "source" => "user" }
          action.buttons    = outcome[:fields].map { |f| f.transform_keys(&:to_s) }
          deferred          = Buddy::ProposalBuilder.claim_deferred(action)
          action.save!
        end
      end

      return { ok: false, errors: ["That form's already been sent."] } if outcome.nil?

      if outcome[:ok]
        finish!(action, outcome)
        Buddy::ProposalBuilder.run_deferred!(action, deferred, executed: true) if deferred.any?
      end

      outcome.slice(:ok, :errors)
    end

    class << self
      private

      # Rebuild the field list from the TOOL, never from what was posted, then
      # validate against that. The browser's copy is a rendering of the form, not
      # the form — and a prompt can also have changed since it was posted.
      def run(action, tool, values, user)
        spec    = tool[:form]
        payload = (action.tool_input["payload"] || {}).symbolize_keys
        ctx     = Buddy::ToolContext.new(user, conversation: action.byte_conversation)
        fields  = Buddy::FormFields.normalize(spec[:fields].call(payload, ctx))

        collected, errors = Buddy::FormFields.collect(fields, values)
        return { ok: false, errors: errors } if errors.any?

        merged = payload.merge(spec[:arg].to_sym => collected)
        # The tool's own confirm is still the authority on whether this can
        # happen — the form only guarantees the SHAPE is right.
        confirm  = tool[:confirm].call(merged, ctx)
        resolved = merged.merge(confirm[:resolved] || {})

        proposal = { "id" => nil, "payload" => stringify(resolved), "tool_name" => tool[:name].to_s }
        exec_ctx = Buddy::ToolContext.new(user, proposal: proposal, conversation: action.byte_conversation)
        result   = Buddy::Tools.dispatch(tool, resolved, exec_ctx)
        return { ok: false, errors: [result[:error].to_s.presence || "That didn't go through."] } unless result[:ok]

        {
          ok:        true,
          collected: collected,
          fields:    Buddy::FormFields.apply_values(fields, collected),
          receipt:   safely { tool[:receipt].call(result[:data], exec_ctx) }.to_s.presence || "Sent ✓",
        }
      rescue StandardError => e
        Rails.logger.warn("[Buddy::FormAction] submit failed: #{e.class}: #{e.message}")
        { ok: false, errors: [e.message.to_s.truncate(200)] }
      end

      # Re-render the form as a read-only summary of what was sent.
      def finish!(action, outcome)
        message = action.byte_message
        return if message.nil?

        form = (message.metadata["form"] || {}).merge(
          "fields"  => outcome[:fields].map { |f| f.transform_keys(&:to_s) },
          "status"  => "submitted",
          "receipt" => outcome[:receipt],
        )
        message.update!(metadata: message.metadata.merge("form" => form, "action_state" => "decided"))
        broadcast(action.user, message.reload)
      end

      def wire(action, fields, spec)
        {
          "tool_name"         => TOOL_NAME,
          "action_request_id" => action.request_id,
          "action_kind"       => "custom",
          "action_state"      => "pending",
          "action_expires_at" => action.expires_at&.iso8601,
          "form"              => {
            "fields" => fields.map { |f| f.transform_keys(&:to_s) },
            "submit" => spec[:submit].to_s.presence || "Send",
            "status" => "pending",
          },
        }
      end

      def post_message(user, conversation, body)
        conversation.byte_messages.create!(
          user:         user,
          direction:    :inbound,
          state:        :delivered,
          body:         body,
          metadata:     { "kind" => "buddy_reply", "source" => "form" },
          delivered_at: Time.current,
        )
      end

      def call_or_value(thing, payload, ctx)
        thing.respond_to?(:call) ? thing.call(payload, ctx) : thing
      end

      def stringify(hash)
        (hash || {}).each_with_object({}) { |(k, v), out|
          out[k.to_s] = v.is_a?(Time) ? v.iso8601 : v
        }
      end

      def safely
        yield
      rescue StandardError => e
        Rails.logger.warn("[Buddy::FormAction] proc raised: #{e.class}: #{e.message}")
        nil
      end

      def broadcast(user, message)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.as_wire },
        })
      end
    end
  end
end
