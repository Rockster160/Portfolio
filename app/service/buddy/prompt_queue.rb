module Buddy
  # Prompts that are asked one at a time.
  #
  # A prompt whose data names a `queue` waits while an earlier prompt in the
  # same queue is still unanswered, and goes out the moment that one is
  # answered, skipped or deleted. So a task can create every follow-up a
  # check-in needs at once, in the order they should be asked, and the person
  # still only ever has the one in front of them.
  #
  # The order is the order they were created in. A prompt with no queue is
  # never held.
  module PromptQueue
    module_function

    KEY = "queue".freeze

    def name_of(prompt)
      params = prompt&.params
      params.is_a?(Hash) ? params[KEY].presence : nil
    end

    # Something earlier in its queue still needs answering first.
    def waiting?(prompt)
      queue = name_of(prompt)
      return false if queue.nil? || prompt.user.nil?

      pending(prompt.user, queue).exists?(id: ...prompt.id)
    end

    def pending(user, queue)
      user.prompts.unanswered.where("prompts.params ->> ? = ?", KEY, queue.to_s)
    end

    # Posts whatever is now at the front of `queue`. One already in the thread
    # is left where it is, since asking it twice would push it twice.
    def advance!(user, queue)
      return if user.nil? || queue.blank?

      front = pending(user, queue).order(:id).first
      return if front.nil? || Buddy::PromptDelivery.open_forms(user, front.id).exists?

      Buddy::PromptDelivery.post!(user, front)
    rescue StandardError => e
      Buddy::Errors.report(section: "prompt_queue.advance", exception: e, user: user, extra: { queue: queue })
      nil
    end
  end
end
