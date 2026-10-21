module Buddy
  # A Buddy message with buttons under it, each of which fires a Jil trigger -
  # "Garage is open!" with "Close the garage" under it.
  #
  # It is a MESSAGE, not an alert: nothing is pinned and nothing stays standing
  # until somebody deals with it. Leaving it unanswered is a real answer.
  #
  # One send can reach several people, each in their own thread, under one
  # `key`. That key is what makes them one question: a press can settle every
  # copy (the other person sees who answered, and their buttons go), and so can
  # a task that sees the thing happen by itself - `Buddy.resolveMessage`.
  #
  # Nothing here knows what a button does. Its trigger scope and data are the
  # sending task's, and a press fires them as the task's owner, exactly as
  # `Global.triggerNow` would, with `pressed_by` added so a listener can say
  # who it was.
  module MessageButtons
    module_function

    TOOL_NAME = "buddy_message_buttons".freeze

    # A color a button may wear: one of the action-button variants, or a hex.
    VARIANTS = %w[primary danger].freeze
    HEX = /\A#\h{3}(?:\h{3})?\z/

    # The wire form of one button, numbered in the order they were written.
    # Raises on a button with nothing to fire: one that does nothing when
    # pressed is a mistake in the task, not a choice.
    def normalize(buttons)
      Array(buttons).each_with_index.map { |button, index|
        button = button.to_h.symbolize_keys
        label = button[:label].to_s.strip
        trigger = button[:trigger].to_s.strip
        raise ::ArgumentError, "a Buddy button needs a label" if label.empty?
        raise ::ArgumentError, "the #{label.inspect} button needs a trigger to fire" if trigger.empty?

        color = button[:color].to_s.strip.downcase
        {
          "id"       => index + 1,
          "label"    => label,
          "trigger"  => trigger,
          "data"     => button[:data].to_h,
          "resolve"  => button[:resolve].nil? || ::ActiveModel::Type::Boolean.new.cast(button[:resolve]),
          "resolved" => button[:resolved].to_s.strip.presence,
          "variant"  => (color if VARIANTS.include?(color)),
          "color"    => (color if color.match?(HEX)),
        }.compact
      }
    end

    # Posts it to each of `users` and returns how many it reached. A copy still
    # waiting under the same key is settled first, quietly: the newer one is the
    # question now.
    def send!(owner:, users:, key:, text:, buttons:)
      text = text.to_s.strip
      return 0 if text.empty? || users.empty?

      key = key.to_s.strip.presence || ::SecureRandom.hex(8)
      wire = normalize(buttons)
      audience = users.map(&:id)

      users.count { |user|
        conversation = ::Buddy::CompanionRelay.conversation_for(user)
        next false if conversation.nil?

        settle_for!(user, owner: owner, key: key, text: nil)
        message = ::Buddy::CompanionDelivery.deliver_plain(
          user:         user,
          conversation: conversation,
          text:         text,
          metadata:     { kind: :buddy, source: :jil },
          push_title:   text,
        )
        attach!(message, owner: owner, key: key, buttons: wire, audience: audience) if wire.any?
        true
      }
    end

    def attach!(message, owner:, key:, buttons:, audience:)
      action = ::ByteAction.create!(
        user:              message.user,
        byte_conversation: message.byte_conversation,
        byte_message:      message,
        kind:              :custom,
        tool_name:         TOOL_NAME,
        multi_select:      false,
        buttons:           buttons,
        tool_input:        { "key" => key, "owner_id" => owner.id, "audience" => audience },
      )
      message.update!(metadata: message.metadata.to_h.merge(
        "tool_name"         => TOOL_NAME,
        "action_request_id" => action.request_id,
        "action_kind"       => "custom",
        "action_state"      => "pending",
        "multi_select"      => false,
        "buttons"           => buttons.map { |b| b.slice("id", "label", "variant", "color") },
      ))
      broadcast!(message)
      action
    end

    # The button this press names, or nil for one the message never offered.
    def button_for(action, value)
      Array(action.buttons).find { |button| button["id"].to_s == value.to_s }
    end

    # A press the controller has already recorded, which is what makes a second
    # press impossible. The answer is shown first - that's what the other person
    # is waiting on - and then the trigger fires.
    def tapped!(action, button, presser)
      input = action.tool_input.to_h
      owner = ::User.find_by(id: input["owner_id"])
      said  = ->(user) { button["resolved"] || "#{user.id == presser.id ? "You" : presser.first_name} pressed \"#{button["label"]}\"" }

      outcome!(action.byte_message, said.call(presser))
      if button["resolve"]
        ::User.where(id: input["audience"]).where.not(id: presser.id).find_each { |user|
          settle_for!(user, owner: owner, key: input["key"], text: said.call(user))
        }
      end
      return if owner.nil?

      data = button["data"].to_h.stringify_keys.merge("pressed_by" => presser.first_name)
      ::Jil.trigger(owner, button["trigger"], data, auth: :trigger)
    end

    # Settles every copy still waiting under `key` that `owner` sent to these
    # users. Returns how many it settled, so a task can tell "I just answered
    # it" from "nobody was being asked".
    def settle!(owner:, users:, key:, text:)
      users.sum { |user| settle_for!(user, owner: owner, key: key, text: text) }
    end

    def settle_for!(user, owner:, key:, text:)
      waiting = ::ByteAction.pending.where(user_id: user.id, tool_name: TOOL_NAME)
      waiting = waiting.where("tool_input->>'key' = ? AND tool_input->>'owner_id' = ?", key.to_s, owner&.id.to_s)
      waiting.to_a.count { |action|
        next false unless action.apply_decision!(value: "settled", source: :system)

        outcome!(action.byte_message, text)
        true
      }
    end

    # What became of it, shown where the buttons were. Blank takes the buttons
    # away and says nothing.
    def outcome!(message, text)
      return if message.nil?

      message.reload.update!(metadata: message.metadata.to_h.merge("buttons_outcome" => text.to_s.strip.presence))
      broadcast!(message)
    end

    # `update: true` repaints the bubble in place: no unread count, no notice.
    def broadcast!(message)
      ::MonitorChannel.broadcast_to(message.user, {
        id:      :byte,
        channel: :byte,
        data:    { kind: :message, message: message.reload.as_wire, update: true },
      })
    end
  end
end
