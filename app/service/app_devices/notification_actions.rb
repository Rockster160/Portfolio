module AppDevices
  # The buttons a native notification carries, so a question can be answered
  # from the lock screen. Each comes back as an `answer` submission, which
  # AppDevices::Answer turns into the same thing the button in the thread does.
  #
  # Only shapes a single tap can settle get buttons. A checklist, a form with
  # several fields or a multi-select opens the app instead.
  module NotificationActions
    module_function

    # iOS shows at most this many actions under a notification.
    MAX = 4
    SINGLE_TAP_PROMPT_TYPES = %w[choices select chips scale checkbox].freeze

    def for_message(message)
      meta = message.metadata.is_a?(Hash) ? message.metadata : {}
      request_id = meta["action_request_id"]
      return {} if request_id.blank? || meta["multi_select"] || meta["action_state"] != "pending"

      buttons = Array(meta["buttons"]).first(MAX)
      return {} if buttons.empty?

      by_id = meta["tool_name"] == Buddy::MessageButtons::TOOL_NAME
      return {} unless by_id || meta["kind"] == "action-request"

      actions = buttons.map { |button|
        value = by_id ? button["id"] : (button["value"] || button["label"])
        {
          id:          "action-#{value}",
          title:       (button["label"] || value).to_s,
          value:       value.to_s,
          destructive: button["variant"].to_s == "danger",
        }
      }
      { actions: actions, answer: { kind: :action, request_id: request_id } }
    end

    # A prompt with one question a tap can answer becomes buttons; one asking
    # for words gets a reply field.
    def for_prompt(prompt)
      options = Array.wrap(prompt.options).map { |option| option.to_h.stringify_keys }
      questions = options.reject { |option| %w[hidden hint].include?(option["type"].to_s) }
      return {} unless questions.one?

      question = questions.first
      answer = { kind: :prompt, prompt_id: prompt.id, question: question["question"].to_s }
      type = question["type"].to_s

      if %w[text textarea number].include?(type)
        reply = { id: "reply", title: "Reply", input: true, placeholder: question["question"].to_s }
        return { actions: [reply], answer: answer }
      end
      return {} unless SINGLE_TAP_PROMPT_TYPES.include?(type)

      choices = choices_for(question)
      return {} if choices.empty? || choices.length > MAX

      {
        actions: choices.map { |choice|
          { id: "choice-#{choice}", title: choice.to_s, value: choice }
        },
        answer:  answer,
      }
    end

    def choices_for(question)
      case question["type"].to_s
      when "checkbox"
        [true, false]
      when "scale"
        min = question["min"].to_i
        max = (question["max"].presence || 5).to_i
        (min..max).to_a
      else
        Array(question["choices"] || question["options"]).map { |choice|
          choice.is_a?(Hash) ? (choice["value"] || choice["label"] || choice["name"]) : choice
        }.compact
      end
    end
  end
end
