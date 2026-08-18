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

    # The key of the button that submits the form's VALUES. Every other button
    # in the footer runs a different tool and ignores the fields entirely — see
    # `actions:` on a tool's form spec.
    SUBMIT_KEY = "submit".freeze

    # Long, for the same reason a proposal checklist is: this sits in the thread
    # and someone may come back to it. The 10-minute ByteAction default is tuned
    # for a Claude hook blocking on a decision, and made checkboxes silently 409.
    TTL = 3.days

    # Build the form and post it. Returns the ByteAction, or nil when the tool
    # can't produce one (its `fields` proc is also its resolver — a prompt that
    # has since been answered raises there rather than posting an empty form).
    def post!(user:, conversation:, tool:, payload:, merge_key: nil, deferred: [], vars: {})
      spec = tool[:form]
      return nil if spec.nil?

      ctx     = Buddy::ToolContext.new(user, conversation: conversation)
      fields  = Buddy::FormFields.normalize(spec[:fields].call(payload, ctx))
      # A form with no fields is still a real question when its footer carries
      # the answers — a yes/no, or one button per option. Only a form with
      # neither fields nor buttons has nothing to ask.
      return nil if fields.empty? && Array(spec[:actions]).empty?

      named   = spec[:title]
      title   = (named.respond_to?(:call) ? named.call(payload, ctx) : named).to_s
      message = post_message(user, conversation, title.presence || tool[:name].to_s.tr("_", " "))

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
          "merge_key" => merge_key,
          "deferred"  => deferred,
          # Values collected before this form, so a step after it can still use
          # them. Rides with the queue, not with the form.
          "vars"      => stringify(vars),
          # What this form has to hear before the queue behind it runs. Stored
          # on the gate like the relay path does it, so advance_queue! finds it
          # in one place whichever kind of question was asked.
          **Buddy::AnswerCondition.build(
            var: payload[:var], is: payload[:continue_if],
          ).then { |c| c ? { "continue_if" => c } : {} },
        },
        expires_at:        TTL.from_now,
      )

      message.update!(metadata: message.metadata.merge(wire(action, fields, spec)))
      broadcast(user, message.reload)
      # An earlier form for the same thing is a question they no longer need to
      # answer — re-asking a prompt with better values shouldn't leave two of it.
      Buddy::Supersede.replace!(action: action, keys: [merge_key])
      action
    rescue StandardError => e
      Buddy::Errors.report(section: "form_action.post", exception: e, user: user)
      nil
    end

    # Run the tool with what the person actually sent.
    #
    # `key` names which footer button was tapped. The default one submits the
    # VALUES and runs the form's own tool; any other runs the tool that button
    # declares and never looks at the fields — a Skip must not fail validation
    # on the boxes it exists to leave empty.
    #
    # Returns { ok:, errors: } — errors render under the form so they can fix and
    # resend rather than losing what they typed.
    def submit!(action, values:, key: nil)
      return { ok: false, errors: ["That form's already been sent."] } unless action.pending?
      return { ok: false, errors: ["That form has expired."] } if action.expires_at&.past?

      tool = Buddy::Tools[action.tool_input["tool_name"].to_s.to_sym]
      return { ok: false, errors: ["I can't run that one anymore."] } if tool.nil?

      # Resolved from the TOOL, like the fields are, so a forged key can only
      # ever name a button this form was actually posted with.
      choice = alternate(tool, key)
      return { ok: false, errors: ["I don't know that button."] } if choice.nil? && !primary?(key)

      user     = action.user
      deferred = []
      outcome  = nil

      action.with_lock do
        # Re-read inside the lock so a double-tap can't run the tool twice.
        action.reload
        next unless action.pending?

        outcome = while_submitting(action) {
          choice ? run_alternate(action, choice, user) : run(action, tool, values, user)
        }
        if outcome[:ok]
          action.state      = :decided
          action.decided_at = Time.current
          action.decision   = { "value" => outcome[:collected], "source" => "user", "action" => outcome[:key] }
          # An alternate leaves the fields alone — it didn't submit them, and
          # rewriting them would show a skipped prompt as if it were answered.
          action.buttons    = outcome[:fields].map { |f| f.transform_keys(&:to_s) } if outcome[:fields]
          deferred          = Buddy::ProposalBuilder.claim_deferred(action)
          action.save!
        end
      end

      return { ok: false, errors: ["That form's already been sent."] } if outcome.nil?

      if outcome[:ok]
        finish!(action, outcome)
        # `captured` is what this form ADDED to the run - an ask_me answer the
        # steps behind it are waiting on. A form that captures nothing passes an
        # empty hash and the queue advances exactly as it always did.
        if deferred.any?
          Buddy::ProposalBuilder.advance_queue!(action, deferred, executed: true, captured: outcome[:captured] || {})
        end
      end

      outcome.slice(:ok, :errors)
    end

    # Forms whose tool is running RIGHT NOW on this thread.
    #
    # `answer_prompt` fires the very same `prompt:complete` trigger the app's own
    # page fires, from inside the submit — so the external settler below comes
    # straight back at the form being submitted. Left alone, both would claim its
    # deferred queue off two copies of the row and run whatever was waiting
    # behind it twice. The submit is already settling it, so the settler stands
    # down.
    SUBMITTING = :buddy_form_submitting

    def while_submitting(action)
      open = Array(Thread.current[SUBMITTING])
      Thread.current[SUBMITTING] = open + [action.id]
      yield
    ensure
      Thread.current[SUBMITTING] = open
    end

    def submitting?(action)
      Array(Thread.current[SUBMITTING]).include?(action.id)
    end

    # Close a form because the thing it was asking about got settled somewhere
    # ELSE — the same prompt answered on its own page, say. Nothing runs here;
    # the work has already happened, and this only brings the copy in the thread
    # into line with it.
    #
    # `values` are what the thing ended up holding, folded onto the fields so
    # the bubble shows the real answer rather than Buddy's guess. Omit them and
    # the fields are left exactly as they were, which is right for a skip: there
    # is no answer to show.
    #
    # Returns true if this closed it, false if it was already settled.
    def settle!(action, receipt:, values: nil, key: nil)
      return false unless action&.pending?
      return false if submitting?(action)

      fields   = nil
      deferred = []
      settled  = false

      action.with_lock do
        action.reload
        next unless action.pending?

        fields            = Buddy::FormFields.apply_values(action.buttons, values) if values
        action.state      = :decided
        action.decided_at = Time.current
        action.decision   = { "value" => values || {}, "source" => "app", "action" => key.to_s.presence }
        action.buttons    = fields.map { |f| f.transform_keys(&:to_s) } if fields
        deferred          = Buddy::ProposalBuilder.claim_deferred(action)
        action.save!
        settled = true
      end
      return false unless settled

      finish!(action, { key: key.to_s.presence, receipt: receipt, fields: fields })
      # Whatever was queued behind this form was waiting for the question to be
      # answered, not for the tap specifically. It has been.
      Buddy::ProposalBuilder.advance_queue!(action, deferred, executed: true, captured: {}) if deferred.any?
      true
    rescue StandardError => e
      Buddy::Errors.report(section: "form_action.settle", exception: e, user: action&.user)
      false
    end

    class << self
      private

      def primary?(key)
        key.blank? || key.to_s == SUBMIT_KEY
      end

      def alternate(tool, key)
        return nil if primary?(key)

        Array(tool.dig(:form, :actions)).find { |choice| choice[:key].to_s == key.to_s }
      end

      # A footer button that isn't the submit. It runs a DIFFERENT tool against
      # the payload this form was posted with — skip_prompt against the prompt
      # id the form is for — so the fields play no part, and neither does
      # whatever the browser sent along with the tap.
      def run_alternate(action, choice, user)
        tool = Buddy::Tools[choice[:tool].to_sym]
        return { ok: false, errors: ["I can't run that one anymore."] } if tool.nil?

        payload = (action.tool_input["payload"] || {}).symbolize_keys
        ctx     = Buddy::ToolContext.new(user, conversation: action.byte_conversation)
        args    = choice[:payload].respond_to?(:call) ? choice[:payload].call(payload, ctx) : payload

        confirm  = tool[:confirm].call(args, ctx)
        resolved = args.merge(confirm[:resolved] || {})

        proposal = { "id" => nil, "payload" => stringify(resolved), "tool_name" => tool[:name].to_s }
        exec_ctx = Buddy::ToolContext.new(user, proposal: proposal, conversation: action.byte_conversation)
        result   = Buddy::Tools.dispatch(tool, resolved, exec_ctx)
        return { ok: false, errors: [result[:error].to_s.presence || "That didn't go through."] } unless result[:ok]

        {
          ok:        true,
          key:       choice[:key].to_s,
          collected: {},
          captured:  {},
          receipt:   safely { tool[:receipt].call(result[:data], exec_ctx) }.to_s.presence || "Done ✓",
        }
      rescue StandardError => e
        Rails.logger.warn("[Buddy::FormAction] #{choice[:key]} failed: #{e.class}: #{e.message}")
        { ok: false, errors: [e.message.to_s.truncate(200)] }
      end

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
          key:       SUBMIT_KEY,
          collected: collected,
          # A tool that exists to collect a value says so by returning
          # `captured:` from its execute; everything else returns nothing here
          # and the run's variables are untouched.
          captured:  (result[:data].is_a?(Hash) ? result[:data][:captured] : nil) || {},
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
          "status"  => "submitted",
          "receipt" => outcome[:receipt],
          # Which button ended it, so the summary can say "Skipped it ✓" over
          # the values that never got sent rather than implying they were.
          "decided" => outcome[:key],
        )
        form["fields"] = outcome[:fields].map { |f| f.transform_keys(&:to_s) } if outcome[:fields]
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
            "fields"  => fields.map { |f| f.transform_keys(&:to_s) },
            "actions" => Buddy::FormFields.buttons(spec),
            "status"  => "pending",
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
