# A production script, posted into the thread its session speaks in, so it can
# be read and approved where its owner already is: the code itself in a box
# that scrolls rather than wraps, with links to the full page, the PR and the
# Claude session above it, and Approve / Skip under it.
#
# The message holds only which script it is. What it shows is read from the
# script each time it is painted, so a card is never out of date: approving it
# anywhere, an edit on the page, a run, all repaint every card for it.
#
# A reply to a card goes to the session that wrote the script, told which
# script it's about (FeatureBuilder.answer_from_thread!).
module ProductionScripts
  module Card
    module_function

    KIND = "production_script".freeze

    def post!(script, updated: false)
      conversation = conversation_for(script)
      return nil if conversation.nil?

      supersede!(script) if updated
      step = updated ? "Changed, so it needs approving again" : "Needs your approval"
      ::Buddy::CompanionDelivery.deliver_plain(
        user:         script.user,
        conversation: conversation,
        text:         body(script, step),
        metadata:     {
          "kind"                 => KIND,
          "source"               => "feature_builder",
          "feature_build_id"     => script.feature_build_id,
          "production_script_id" => script.id,
          # The badge already says it's waiting; only a change needs saying.
          "step"                 => (step if updated),
        }.compact,
        push_title:   "Script: #{script.title}",
      )
    end

    # Where its build speaks, or the owner's primary Buddy thread.
    def conversation_for(script)
      target = script.feature_build&.byte_conversation
      target = ByteConversation.for_self_initiated(script.user) if target.nil? || target.archived?
      target
    end

    # What the message says without the card: the push, a copy, Buddy's history.
    def body(script, step)
      "**#{script.title}**\n#{step}\n[See the whole script](#{url(script)})"
    end

    def url(script)
      Rails.application.routes.url_helpers.system_production_script_url(script)
    end

    def messages(script)
      ByteMessage.where(user_id: script.user_id).where(
        "byte_messages.metadata->>'kind' = ? AND byte_messages.metadata->>'production_script_id' = ?",
        KIND,
        script.id.to_s,
      )
    end

    # The script a message is the card for, or nil.
    def script_for(message)
      return nil if message.nil?

      metadata = message.metadata.to_h
      return nil unless metadata["kind"] == KIND

      ProductionScript.find_by(id: metadata["production_script_id"], user_id: message.user_id)
    end

    # The cards already posted for it, once a newer version has its own: they
    # keep their header and point down to it instead of showing the code twice.
    # Each is repainted as it's marked, since the edit's own repaint went out
    # while it still looked current, Approve and all.
    def supersede!(script)
      messages(script).includes(:user).find_each { |message|
        next if message.metadata.to_h["superseded"]

        message.update!(metadata: message.metadata.to_h.merge("superseded" => true))
        broadcast!(message)
      }
    end

    def repaint!(script)
      messages(script).includes(:user).find_each { |message| broadcast!(message) }
    end

    def broadcast!(message)
      MonitorChannel.broadcast_to(message.user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: message.as_wire, update: true },
      })
    end

    # What the client draws the card from.
    def wire(message)
      script = script_for(message)
      return nil if script.nil?

      build = script.feature_build
      {
        id:          script.id,
        title:       script.title,
        status:      script.status,
        label:       script.status_label,
        approvable:  script.approvable?,
        skippable:   !script.status_running? && !script.status_succeeded? && !script.status_skipped?,
        deployed:    ProductionScripts.deployed?(script.commit_sha),
        url:         url(script),
        commit:      script.short_sha,
        commit_url:  script.commit_url,
        pr_url:      build&.pr_url.presence,
        pr_number:   build&.pr_number,
        session_url: build&.rc_url.presence,
        superseded:  message.metadata.to_h["superseded"] == true,
        settled:     script.status_succeeded? || script.status_skipped?,
        step:        message.metadata.to_h["step"],
        html:        code_html(script.code),
      }
    end

    # The highlighted code, laid out the way the script page lays it out: plain
    # code, and each heredoc as a block of its own, a Jil one marked with
    # whether it validates.
    def code_html(code)
      RubyHighlight.segments(code).map { |segment|
        next "<pre>#{segment.html}</pre>" unless segment.heredoc?

        classes = segment.jil? ? "ps-heredoc ps-jil" : "ps-heredoc"
        "<div class=\"#{classes}\">#{jil_check(segment)}<pre>#{segment.html}</pre></div>"
      }.join
    end

    def jil_check(segment)
      return "" unless segment.jil?

      if segment.valid?
        "<details class=\"ps-check ps-valid\" title=\"Valid Jil\"><summary>✓</summary></details>"
      else
        error = ERB::Util.html_escape(segment.error)
        "<details class=\"ps-check ps-invalid\" title=\"Jil validation failed\"><summary>✗</summary>" \
          "<div class=\"ps-check-error\">#{error}</div></details>"
      end
    end
  end
end
