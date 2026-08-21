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
      action  = reminder.action_call

      return skip!(reminder) unless condition_met?(reminder)

      if action
        run_action(reminder, action)
      elsif command
        run_command(reminder, command)
      elsif reminder.notify_user_id
        deliver_cross_user_reminder(reminder)
      elsif reminder.kind == "prompt"
        deliver_prompted_reminder(user, conversation, reminder)
      else
        deliver_plain_reminder(user, conversation, reminder)
      end

      roll_forward!(reminder)
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

    # Is this still worth saying?
    #
    # An unanswerable condition FIRES. Both outcomes are wrong and they aren't
    # equally wrong: a nudge that arrives when it needn't is noise the person
    # can ignore, and one that silently vanishes is the thing they asked to be
    # told about, gone, with nothing anywhere to say it was ever due. So a
    # broken condition degrades to no condition, loudly.
    def condition_met?(reminder)
      ScheduleCondition.met?(reminder.condition, user: reminder.user)
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "reminder_firer.condition",
        exception: e,
        user:      reminder.user,
        extra:     { reminder_id: reminder.id, condition: reminder.condition },
      )
      true
    end

    # The condition said no. Nothing is posted and nothing is pushed — that IS
    # the feature — but the row still moves, so a skipped reminder leaves
    # `fired_at` behind like a delivered one and stops being pending. Which
    # means it stays visible in context as `status: already_rang` and Buddy can
    # answer "did that go off?" honestly instead of the row simply vanishing.
    #
    # A recurring one rolls forward exactly as a fired one does: skipping
    # tonight is not skipping every night.
    def skip!(reminder)
      Rails.logger.info(
        "[Buddy::ReminderFirer] skipped ##{reminder.id} — #{ScheduleCondition.describe(reminder.condition)}",
      )
      ScheduleCondition.announce_skip!(
        user:         reminder.user,
        conversation: reminder.byte_conversation,
        condition:    reminder.condition,
        subject:      reminder.body.to_s.truncate(60),
      )
      reminder.update!(metadata: reminder.metadata.to_h.merge("last_skipped_at" => Time.current))
      roll_forward!(reminder)
    end

    # Where a fired reminder and a skipped one end up the same: recurring rolls
    # `fire_at` to the next occurrence and stays pending; a one-shot, or a
    # pattern that has run out, goes terminal on `fired_at`.
    def roll_forward!(reminder)
      return reminder.update!(fired_at: Time.current) unless reminder.recurring?

      next_fire = next_fire_for(reminder)
      if next_fire
        reminder.update!(last_fired_at: Time.current, fire_at: next_fire)
      else
        # Bad recurrence spec - treat as one-shot rather than loop forever.
        reminder.update!(fired_at: Time.current, last_fired_at: Time.current)
      end
    end

    # Where the briefing rolls to, and it is NOT simply "the next slot after
    # now".
    #
    # The Today briefing's `at` is a latest-by rather than a fixed hour:
    # Buddy::TodaySchedule pulls it EARLIER for a day that starts early. That
    # makes two things true at once, and both of them bite here.
    #
    #   1. Rolling from `now` lands on TODAY's own nominal slot, because the
    #      briefing fired before it. 8:30 pulled back to 8:00 for a 8:30 Focus
    #      block fires at 8:00, and "the next daily 8:30 after 8:00" is 8:30
    #      the same morning - a second briefing an hour later. So a briefing
    #      rolls from the END of the perceived day, which is tomorrow's slot.
    #   2. The pull-back can land in the PAST, and a `fire_at` in the past is
    #      due on every scheduler tick. On 21 Aug that produced a fixed point:
    #      agenda item 1006 at 8:30, minus the 30-minute lead, is 8:00 exactly,
    #      so every roll recomputed the same past time and Byte briefed once a
    #      minute for ten minutes until the reminder was cancelled by hand.
    #
    # So: roll from the end of the day, and never accept an adjustment that
    # isn't actually ahead of us.
    def next_fire_for(reminder)
      return reminder.next_fire_at(from: Time.current) unless Buddy::TodaySchedule.briefing?(reminder)

      _, day_end = Buddy::Day.range(reminder.user)
      nominal    = reminder.next_fire_at(from: [day_end, Time.current].max)
      return nil if nominal.nil?

      earlier = Buddy::TodaySchedule.fire_time(reminder.user, nominal)
      earlier && earlier > Time.current ? earlier : nominal
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

      # A reminder aimed at somebody ELSE is a message from the person who set
      # it, just one that leaves later - so it goes out the way an immediate
      # message_partner does, bridged. That's what puts the recipient's copy
      # under the sender's companion and, the half that was missing entirely,
      # the matching copy in the sender's own thread. The row stays with the
      # requester either way; only the delivery moves.
      def deliver_cross_user_reminder(reminder)
        recipient = reminder.notify_user
        return if recipient.nil?

        owner = reminder.user
        said  = Buddy::Template.render(
          reminder.body, {}, user: owner, conversation: reminder.byte_conversation
        )
        Buddy::CompanionRelay.pass_along!(
          from:              owner,
          to:                recipient,
          text:              said,
          from_conversation: reminder.byte_conversation,
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

      # A stored tool call, replayed. Same `run_markers!` a routine goes through,
      # for the same reason: the marker path already handles resolution, level,
      # receipts and the empty-result line, so a scheduled call behaves exactly
      # like the same call typed out by hand.
      #
      # The reminder's own body is the line over it. Whoever set it wrote that
      # sentence to be read at this moment, and it says what the call is for far
      # better than a generated heading would.
      #
      # Unless the tool posts a whole message of ITS own (`speaks: true`), in
      # which case there is no line at all. The morning briefing is the one:
      # "Today briefing" sitting above a message that opens with its own
      # greeting lands directly on the line that briefing's prompt works hardest
      # to get right.
      def run_action(reminder, action)
        conversation = reminder.byte_conversation
        return if conversation.nil?

        speaks = Buddy::Tools.speaks?(Buddy::Tools[action[:tool_name]])
        Buddy::ProposalBuilder.run_markers!(
          user:         reminder.user,
          conversation: conversation,
          markers:      [action],
          body:         (reminder.body.to_s.presence || "Running that now." unless speaks),
        )
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
