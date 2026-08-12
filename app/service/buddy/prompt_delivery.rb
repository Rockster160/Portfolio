module Buddy
  # Puts a pending Prompt into the Byte thread as the editable form it already
  # knows how to be.
  #
  # A "Who did: Puppy Down?" prompt is one dropdown and a timestamp that's
  # already right, and answering it in the app costs a notification, a tap
  # through to /prompts, a page, and a submit. `answer_prompt` has carried a
  # `:form` spec this whole time - Buddy fills a prompt in and posts it as
  # widgets the person can correct - and nothing but a model turn could reach
  # it. This is the other door: the same form, posted the moment the prompt
  # exists, with nothing filled in that wasn't already.
  #
  # No model call. There is nothing to reason about — the fields come from the
  # prompt, the answer comes from the person, and asking a model to sit in the
  # middle of that would cost a turn to add nothing.
  module PromptDelivery
    module_function

    # What a prompt can END as, and what the settled form in the thread says it
    # was. Every other status (`load` above all, which fires on every page view)
    # leaves the form alone.
    ENDINGS = {
      "complete" => "Answered in the app ✓",
      "skip"     => "Skipped in the app ✓",
    }.freeze

    # A prompt Buddy posted can also be answered on its own page, and until it
    # settles here the thread still shows an open form for a question that has
    # no answer left to give. Tapping it got a bare "no pending prompt" — the
    # refusal was right and it arrived far too late to be the explanation.
    #
    # Rides the Jil trigger bus rather than a Prompt callback so it covers every
    # door at once: the controller, a Jil task answering one, Buddy's own tools.
    # Bails on the trigger name, so it costs one comparison for everything else.
    def dispatch(user, trigger, payload)
      return unless trigger.to_s == "prompt"

      status  = jil_attr(payload, :status).to_s
      receipt = ENDINGS[status]
      return if receipt.nil?

      id = jil_attr(payload, :id) || payload.try(:id)
      return if id.blank?

      # A skipped prompt has no answer to fold in, so its form keeps whatever it
      # was showing and only stops being answerable.
      values = status == "complete" ? response_of(payload) : nil
      open_forms(user, id).each { |action| Buddy::FormAction.settle!(action, receipt: receipt, values: values) }
    rescue StandardError => e
      Rails.logger.warn("[Buddy::PromptDelivery] settle failed: #{e.class}: #{e.message}")
      nil
    end

    # Pending forms in ANY of their threads pointing at this prompt. Keyed on
    # the payload the form was posted with rather than on `merge_key`, which
    # only gets stored when the tool supersedes.
    def open_forms(user, prompt_id)
      user.byte_actions.where(
        tool_name: Buddy::FormAction::TOOL_NAME,
        state:     :pending,
      ).where(
        "tool_input->>'tool_name' = ? AND tool_input->'payload'->>'id' = ?",
        "answer_prompt", prompt_id.to_s
      )
    end

    # Trigger payloads arrive as the Prompt itself carrying Jil attrs (see
    # Jilable#[]), and occasionally as a plain hash.
    def jil_attr(payload, key)
      return payload[key] || payload[key.to_s] if payload.is_a?(Hash)

      payload.try(:[], key)
    end

    def response_of(payload)
      response = payload.is_a?(Hash) ? payload[:response] || payload["response"] : payload.try(:response)
      response.is_a?(Hash) ? response : nil
    end

    # Post `prompt` as a form in the person's Buddy thread. Returns the
    # ByteAction, or nil when there's nowhere to put it. Never raises: a prompt
    # that doesn't reach the thread is still sitting in the app.
    def post!(user, prompt)
      return nil unless deliverable?(user, prompt)

      conversation = conversation_for(user)
      return nil if conversation.nil?

      action = Buddy::FormAction.post!(
        user:         user,
        conversation: conversation,
        tool:         Buddy::Tools[:answer_prompt],
        payload:      { id: prompt.id, answers: {} },
        # One form per prompt however it got here, so a re-ask replaces the
        # question in the thread rather than stacking a second copy of it.
        merge_key:    "answer_prompt:#{prompt.id}",
      )
      notify!(user, action)
      action
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "prompt_delivery.post",
        exception: e,
        user:      user,
        extra:     { prompt_id: prompt&.id },
      )
      nil
    end

    # Ask out loud. A form posted from a TURN needs no push - they're looking at
    # the thread, they just spoke to it - but this one fires off an event nobody
    # is watching for, and a question nobody is told about is a question that
    # gets answered whenever they next happen to open the app. That's the whole
    # trade being made by not pushing it from the prompt side.
    #
    # Presence is deliberately ignored, same as a reminder or a watch: the chore
    # happened when it happened.
    def notify!(user, action)
      message = action&.byte_message
      return if message.nil?
      # A form on the wall is answered by tapping the wall. Same rule as
      # ByteNotifier: the kiosk never pushes.
      return if message.byte_conversation&.kiosk?

      # The message body IS the question ("Who did: Puppy Down?"), and the OS
      # already shows Byte's name and icon around it, so nothing is added here.
      WebPushNotifications.send_to_byte(
        title: message.body.to_s.truncate(160),
        tag:   "byte-#{message.id}",
        users: [user],
      )
    rescue StandardError => e
      Rails.logger.warn("[Buddy::PromptDelivery] notify failed: #{e.class}: #{e.message}")
    end

    def deliverable?(user, prompt)
      return false if user.nil? || prompt.nil? || prompt.response.present?

      Buddy::Features.enabled?(user, :prompts)
    end

    # Their newest live Buddy thread, which is the one they're actually reading.
    # A form posted into an archived thread is a form nobody sees, and there's
    # no point starting a thread for it either - somebody with no companion is
    # answering this in the app.
    def conversation_for(user)
      ByteConversation.for_self_initiated(user)
    end
  end
end
