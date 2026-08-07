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

    # Post `prompt` as a form in the person's Buddy thread. Returns the
    # ByteAction, or nil when there's nowhere to put it. Never raises: a prompt
    # that doesn't reach the thread is still sitting in the app.
    def post!(user, prompt)
      return nil unless deliverable?(user, prompt)

      conversation = conversation_for(user)
      return nil if conversation.nil?

      Buddy::FormAction.post!(
        user:         user,
        conversation: conversation,
        tool:         Buddy::Tools[:answer_prompt],
        payload:      { id: prompt.id, answers: {} },
        # One form per prompt however it got here, so a re-ask replaces the
        # question in the thread rather than stacking a second copy of it.
        merge_key:    "answer_prompt:#{prompt.id}",
      )
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "prompt_delivery.post",
        exception: e,
        user:      user,
        extra:     { prompt_id: prompt&.id },
      )
      nil
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
      user.byte_conversations.active.buddy.ordered.first
    end
  end
end
