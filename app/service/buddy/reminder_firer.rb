module Buddy
  # Fires a BuddyReminder: creates the visible message in its
  # conversation, marks the reminder fired, broadcasts + notifies.
  # For `prompt` kind, also dispatches a fresh Buddy turn so the model
  # composes a contextual reply at fire-time (uses the same hidden-
  # trigger pattern as the quick-action buttons).
  module ReminderFirer
    module_function

    def fire!(reminder)
      return if reminder.fired_at.present? || reminder.cancelled_at.present?

      conversation = reminder.byte_conversation
      user         = reminder.user

      # Worked out HERE, not when the reminder was set. `kind` is chosen once,
      # by the model, and is invisible from then on - so a reminder that was
      # meant to do something arrives as a line of text, and there's nowhere to
      # notice. Resolving at fire time also degrades honestly: rename the
      # routine and it goes back to being a nudge rather than running the
      # nearest match.
      command = reminder.command

      if command
        run_command(reminder, command)
      elsif reminder.notify_user_id
        deliver_cross_user_reminder(reminder)
      elsif reminder.kind == "prompt"
        deliver_prompted_reminder(user, conversation, reminder)
      else
        deliver_plain_reminder(user, conversation, reminder)
      end

      # Recurring: roll fire_at forward to the next occurrence, keep
      # the row pending. Non-recurring: terminal fired_at.
      if reminder.recurring?
        next_fire = reminder.next_fire_at(from: Time.current)
        if next_fire
          reminder.update!(last_fired_at: Time.current, fire_at: next_fire)
        else
          # Bad recurrence spec - treat as one-shot rather than loop forever.
          reminder.update!(fired_at: Time.current, last_fired_at: Time.current)
        end
      else
        reminder.update!(fired_at: Time.current)
      end
    rescue StandardError => e
      # Firing a reminder failing is a data-integrity event: the user
      # asked to be reminded of something at a specific time and the
      # nudge did not fire. Route through Buddy::Errors so it shows up
      # in Slack immediately - a missed reminder in silent-log-only
      # would go unnoticed for hours.
      Buddy::Errors.report(
        section:   "reminder_firer.fire",
        exception: e,
        user:      reminder.user,
        extra:     { reminder_id: reminder.id, kind: reminder.kind },
      )
    end

    class << self
      private

      # A simple text message from Buddy. Delivered as inbound so the
      # standard notify path fires (push notification, presence-aware).
      #
      # No leading glyph: one that opens every reminder stops saying "reminder"
      # by the second one, and someone with a day full of them reads the same
      # character a dozen times before the words.
      def deliver_plain_reminder(user, conversation, reminder)
        # The body is a Liquid template like any other editable one. A reminder
        # has no trigger payload behind it, so what it reaches is the base
        # context - the clock, the day, their name, the pet's - which is enough
        # for "{{ greeting }}, {{ user }} - bins go out tonight".
        said = Buddy::Template.render(reminder.body, {}, user: user, conversation: conversation)
        Buddy::CompanionDelivery.deliver_plain(
          user:         user,
          conversation: conversation,
          text:         "Reminder: #{said}",
          metadata:     { kind: "buddy", source: "reminder", reminder_id: reminder.id },
          push_title:   said,
        )
      end

      # A reminder somebody set FOR someone else lands on the recipient's own
      # companion, in that companion's voice, attributed to whoever asked. Same
      # shape as a cross-user watch (Buddy::WatchMatcher#fire_cross_user!) -
      # the row stays with the requester, only the delivery moves.
      def deliver_cross_user_reminder(reminder)
        owner     = reminder.user
        recipient = reminder.notify_user
        said      = Buddy::Template.render(
          reminder.body, {}, user: owner, conversation: reminder.byte_conversation
        )

        Buddy::CompanionDelivery.deliver_prompt(
          user:         recipient,
          conversation: Buddy::CompanionRelay.conversation_for(recipient),
          # Quoted and attributed for the same reason the watch relay is: a bare
          # imperative reads as an instruction to the companion, which answers
          # "yep, sent it along" instead of saying the thing.
          seed:         "#{owner.first_name} asked me to remind #{recipient.first_name} " \
                        "at this time: \"#{said}\". Say it to them warmly, in your own " \
                        "voice - you're passing it along for #{owner.first_name}, so don't " \
                        "read the request back as though it were addressed to you.",
          metadata:     {
            kind:        "buddy_trigger",
            hidden:      true,
            source:      "reminder_relay",
            reminder_id: reminder.id,
          },
        )
      end

      # The reminder was an instruction, so carry it out rather than reading it
      # back. No model on this path - the target was resolved by name a moment
      # ago, and a saved sequence firing on a clock shouldn't cost a turn or
      # come out differently each time.
      def run_command(reminder, command)
        if command[:kind] == :routine
          Buddy::Routines.run!(command[:routine], conversation: reminder.byte_conversation)
        else
          ::Jil.trigger(reminder.user, command[:scope].to_sym, {}, auth: :buddy, auth_id: reminder.user_id)
          command_chip(reminder, command[:name])
        end
      end

      # A Jil task leaves nothing behind on its own, so say what ran. A routine
      # posts its own message through run_markers!, which is why only this
      # branch needs one.
      def command_chip(reminder, name)
        conversation = reminder.byte_conversation
        return if conversation.nil?

        message = conversation.byte_messages.create!(
          user:         reminder.user,
          direction:    :inbound,
          state:        :delivered,
          body:         "Fired **#{name}** ⚡",
          metadata:     {
            "kind"        => "buddy_activity",
            "tool_name"   => "trigger_jil_task",
            "ok"          => true,
            "source"      => "reminder",
            "reminder_id" => reminder.id,
          },
          delivered_at: Time.current,
        )
        MonitorChannel.broadcast_to(
          reminder.user,
          { id: :byte, channel: :byte, data: { kind: :message, message: message.as_wire } },
        )
      end

      # Trigger a Buddy turn as if the user tapped a quick action - the
      # reminder body becomes the synthetic prompt. Same hidden-message
      # pattern as Buddy::QuickActionsController.
      def deliver_prompted_reminder(user, conversation, reminder)
        Buddy::CompanionDelivery.deliver_prompt(
          user:         user,
          conversation: conversation,
          seed:         reminder.body,
          metadata:     {
            kind:        "buddy_trigger",
            hidden:      true,
            source:      "reminder",
            reminder_id: reminder.id,
          },
        )
      end
    end
  end
end
