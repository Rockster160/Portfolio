module Buddy
  # Companion-to-companion messaging between household partners. One person's
  # Buddy relays a message (or a question) into the OTHER person's Buddy, in
  # that Buddy's own voice, and — for questions — carries the answer back.
  #
  # Delivery mechanics ride on Buddy::CompanionDelivery (the same "Buddy speaks
  # on its own" path reminders/watches use); this module owns the cross-user
  # framing and the answer round-trip. A BuddyRelay row is the durable state
  # that spans the two users/conversations.
  #
  #   notify      -> deliver_prompt: recipient's Buddy phrases + delivers it.
  #   ask_open    -> deliver_prompt: recipient's Buddy asks; it emits a
  #                  [[relay_answer]] marker on a LATER turn once answered
  #                  (the open relay is surfaced in that turn's context).
  #   ask_choice/ -> a plain attributed prompt + a checkbox ByteAction the
  #   ask_multi      recipient taps; the answer comes through respond_action.
  module CompanionRelay
    class << self
      # ---- resolving the recipient + their conversation ----

      def conversation_for(user)
        user.byte_conversations.where(mode: :buddy).order(last_message_at: :desc).first ||
          user.byte_conversations.create!(name: :Buddy, mode: :buddy)
      end

      # ---- delivering a relay to the recipient ----

      # Dispatch by kind. Returns the relay.
      def deliver!(relay)
        case relay.kind.to_sym
        when :notify   then send_notify(relay)
        when :ask_open then send_open_question(relay)
        else                send_choice_question(relay)
        end
        relay
      end

      def send_notify(relay)
        deliver_seed(relay, notify_seed(relay))
      end

      def send_open_question(relay)
        deliver_seed(relay, open_question_seed(relay))
      end

      # Structured pick-one / pick-any: a deterministic attributed message with
      # a checkbox action under it. The recipient's answer returns through
      # ByteController#respond_buddy_relay.
      def send_choice_question(relay)
        convo   = conversation_for(relay.to_user)
        message = convo.byte_messages.create!(
          user:         relay.to_user,
          direction:    :inbound,
          state:        :delivered,
          body:         choice_body(relay),
          metadata:     {},
          delivered_at: Time.current,
        )
        action = attach_answer_action(relay, message)
        relay.update!(
          to_conversation: convo,
          to_byte_action:  action,
          status:          :delivered,
          delivered_at:    Time.current,
        )
        broadcast(relay.to_user, message.reload)
        push(relay.to_user, choice_push(relay))
        relay
      end

      # ---- capturing the answer + relaying it back ----

      # Records the recipient's answer (a String for open/choice, an Array for
      # multi) and hands it back to the asker's Buddy. Idempotent: a relay that
      # is no longer awaiting an answer is left untouched.
      def record_answer!(relay, answer)
        return relay unless relay.delivered? && relay.question?

        relay.update!(answer: answer, status: :answered, answered_at: Time.current)
        relay_answer_back(relay)
        relay
      end

      def relay_answer_back(relay)
        convo = relay.from_conversation || conversation_for(relay.from_user)
        Buddy::CompanionDelivery.deliver_prompt(
          user:         relay.from_user,
          conversation: convo,
          seed:         answer_back_seed(relay),
          metadata:     { kind: "buddy_trigger", hidden: true, source: "relay_answer", relay_id: relay.id },
        )
        relay.update!(status: :relayed, from_conversation: convo)
      end

      # A checkbox answer (choice/multi) came back from the recipient. Map the
      # tapped button ids to their option labels, record the answer, and lock
      # the checklist. `choice` collapses to a single string; `multi` stays an
      # array.
      def answer_from_action(action, checked_ids)
        relay = BuddyRelay.find_by(id: action.tool_input["relay_id"])
        return if relay.nil? || !relay.delivered?

        labels = Array(action.buttons)
          .select { |b| checked_ids.include?(b["id"].to_i) }
          .map { |b| b["label"].to_s }
        answer = relay.ask_multi? ? labels : labels.first

        record_answer!(relay, answer)
        finalize_action!(action, checked_ids)
        relay
      end

      private

      # Lock the recipient's checklist: mark tapped rows executed, the rest
      # cancelled, decide the action, and re-broadcast so the UI settles.
      def finalize_action!(action, checked_ids)
        action.apply_decision!(value: checked_ids.map(&:to_s), source: :user) if action.pending?

        buttons = Array(action.buttons).map(&:dup)
        buttons.each { |b| b["status"] = checked_ids.include?(b["id"].to_i) ? "executed" : "cancelled" }
        action.update!(buttons: buttons)

        message = action.byte_message
        return if message.nil?

        message.update!(metadata: message.metadata.merge("buttons" => buttons, "action_state" => "decided"))
        broadcast(action.user, message.reload)
      end

      # deliver_prompt re-runs a fresh in-character turn for the RECIPIENT, so
      # the message reads like their own Byte/Moss talking. The seed is the
      # instruction; the visible reply is what their Buddy composes from it.
      def deliver_seed(relay, seed)
        convo = conversation_for(relay.to_user)
        Buddy::CompanionDelivery.deliver_prompt(
          user:         relay.to_user,
          conversation: convo,
          seed:         seed,
          metadata:     { kind: "buddy_trigger", hidden: true, source: "relay", relay_id: relay.id },
        )
        relay.update!(to_conversation: convo, status: :delivered, delivered_at: Time.current)
      end

      # ---- seed / body copy ----

      def notify_seed(relay)
        "Pass a message from #{from_name(relay)} (their partner) to #{to_name(relay)}, in your own voice: " \
          "#{relay.body}. Just let them know warmly — this isn't a question, nothing to confirm."
      end

      def open_question_seed(relay)
        "#{from_name(relay)} (their partner) wants to ask #{to_name(relay)} something — ask it naturally, " \
          "in your own voice, and let them answer however they like: \"#{relay.body}\". " \
          "You don't need to do anything else this turn; once they've actually answered you'll pass it back."
      end

      def answer_back_seed(relay)
        "#{to_name(relay)} answered the question you passed along from #{from_name(relay)} " \
          "(\"#{relay.body}\"). Their answer: #{formatted_answer(relay)}. Let #{from_name(relay)} know, " \
          "warmly and in your own voice."
      end

      def choice_body(relay)
        lead = "#{from_name(relay)} is asking:"
        tail = relay.ask_multi? ? " Check any that fit." : " Tap the one that fits."
        "#{lead} #{relay.body}#{tail}"
      end

      def choice_push(relay)
        "#{from_name(relay)} is asking: #{relay.body}"
      end

      def formatted_answer(relay)
        if relay.ask_multi?
          picked = Array(relay.answer).compact_blank
          picked.any? ? picked.join(", ") : "none of them"
        else
          relay.answer.to_s.presence || "(no answer)"
        end
      end

      # ---- the recipient-side checkbox action ----

      def attach_answer_action(relay, message)
        buttons = Array(relay.options).each_with_index.map { |opt, i|
          { "id" => i + 1, "label" => opt.to_s, "tool_name" => "buddy_relay_answer", "status" => "pending" }
        }
        action = ByteAction.create!(
          user:              relay.to_user,
          byte_conversation: message.byte_conversation,
          byte_message:      message,
          kind:              :custom,
          tool_name:         "buddy_relay_answer",
          multi_select:      true,
          buttons:           buttons,
          tool_input:        { "relay_id" => relay.id, "mode" => relay.kind },
        )

        message.update!(metadata: message.metadata.merge(
          "kind"              => "buddy_reply",
          "tool_name"         => "buddy_relay_answer",
          "action_request_id" => action.request_id,
          "action_kind"       => "custom",
          "action_state"      => "pending",
          "multi_select"      => true,
          "buttons"           => buttons,
          # "confirm" = pick-any with a Send button; "instant" = tap-to-answer.
          "select_mode"       => relay.ask_multi? ? "confirm" : "instant",
        ))
        action
      end

      # ---- shared broadcast / push (same shape as CompanionDelivery) ----

      def broadcast(user, message)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :message, message: message.as_wire },
        })
      end

      def push(user, title)
        WebPushNotifications.send_to_byte(
          title: "💬 #{title.to_s.truncate(160)}",
          tag:   "byte-relay-#{user.id}-#{Time.current.to_i}",
          users: [user],
        )
      end

      def from_name(relay)
        relay.from_user.first_name.presence || "your partner"
      end

      def to_name(relay)
        relay.to_user.first_name.presence || "them"
      end
    end
  end
end
