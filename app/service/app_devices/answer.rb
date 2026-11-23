module AppDevices
  # A notification button pressed on the phone: the same answer the button in
  # the thread or the prompt page gives, reached without opening anything.
  module Answer
    module_function

    def call(user:, data:)
      data = data.to_h.deep_symbolize_keys
      return prompt(user, data) if data[:prompt_id].present?
      return action(user, data) if data[:request_id].present?

      # A button with no prompt or action behind it only fires the
      # ios_notification_action trigger, which the caller does.
      "Sent"
    end

    def prompt(user, data)
      prompt = user.prompts.find_by(id: data[:prompt_id])
      raise ArgumentError, "that question is gone" if prompt.nil?
      return "Already answered" if prompt.response.present?

      answers = data[:answers].to_h.stringify_keys
      if answers.empty? && data[:question].present?
        answers = { data[:question].to_s => data[:value] }
      end
      prompt.update!(response: answers)
      completed = prompt.with_jil_attrs(status: :complete)
      ::Jil.trigger(user, :prompt, completed, auth: :trigger, auth_id: user.id)
      "Answered"
    end

    def action(user, data)
      action = user.byte_actions.find_by(request_id: data[:request_id])
      raise ArgumentError, "that question is gone" if action.nil?
      return "Already answered" unless action.pending?

      value = data[:value].to_s
      if action.tool_name == ::Buddy::MessageButtons::TOOL_NAME
        button = ::Buddy::MessageButtons.button_for(action, value)
        raise ArgumentError, "that button isn't there anymore" if button.nil?
        return "Already answered" unless action.apply_decision!(value: button["id"], source: :user)

        ::Buddy::MessageButtons.tapped!(action, button, user)
        return "Pressed #{button["label"]}"
      end

      if action.tool_name == ::Buddy::Disambiguation::TOOL_NAME
        button = Array(action.buttons).find { |b| b["value"].to_s == value }
        raise ArgumentError, "that choice isn't there anymore" if button.nil?

        action.apply_decision!(value: value, source: :user)
        ::Buddy::Disambiguation.chose!(action, button)
        return "Chose #{button["label"]}"
      end

      action.apply_decision!(value: value, source: :user)
      if action.byte_message
        ::MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: action.byte_message.reload.as_wire },
        })
      end
      case action.tool_name
      when ::Buddy::TimerCycle::TOOL_NAME then ::Buddy::TimerCycle.tapped!(action)
      when ::Buddy::RotationTimer::TOOL_NAME then ::Buddy::RotationTimer.tapped!(action)
      end
      "Answered"
    end
  end
end
