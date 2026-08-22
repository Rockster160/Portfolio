module Buddy
  # Work / break cycles: "stay on the cupboards until 6:30, but give me ten
  # minutes off every half hour."
  #
  # A cycle is an ordinary Buddy timer carrying a `cycle` key in its metadata.
  # When it fires, instead of just announcing that time is up it posts a card
  # with ONE button, and the next block starts when that button is tapped.
  #
  # Nothing restarts on its own, and that is the whole design. `Timer#repeat`
  # exists and is driven by the CLIENT — it detects the fire and POSTs /start —
  # so a repeating timer keeps its own schedule whether or not the person came
  # back to it, and a cycle built on that drifts out of step with the human
  # inside two rounds. The tap is what keeps the two aligned: the next block
  # starts when they actually start.
  #
  # The break countdown is the one thing that DOES start by itself, at the
  # moment the button appears, because that's the half they want counted for
  # them. It's a plain timer with no cycle of its own, and tapping the button
  # early stops it — otherwise it fires in the middle of the next block and
  # announces a break that finished ten minutes ago.
  #
  # Prod: Eve asked for exactly this on 20 Aug (message 4135) and got one
  # 30-minute timer with an empty `then_continue` queue, plus a reply
  # describing a cycle that didn't exist.
  module TimerCycle
    module_function

    TOOL_NAME = "buddy_timer_cycle".freeze
    KEY       = "cycle".freeze
    RESUME    = "resume".freeze
    # Ending the block you're in, early. The rhythm is a promise about SHAPE,
    # not a sentence — finishing the washing up in four of your fifteen minutes
    # and then sitting out the other eleven is the opposite of the point.
    SKIP      = "skip".freeze

    # A card nobody taps shouldn't be tappable next Tuesday. Long enough to
    # cover a break that ran over, short enough that yesterday's block can't be
    # restarted by a stray tap while scrolling.
    CARD_TTL = 6.hours

    # ---- reading one --------------------------------------------------------

    def cycle_for(timer)
      meta = timer&.metadata
      return nil unless meta.is_a?(Hash)

      cycle = meta[KEY]
      cycle.is_a?(Hash) ? cycle : nil
    end

    def cycle?(timer)
      cycle_for(timer).present?
    end

    # Past the end of what they asked for. Blank `until_at` means "keep going
    # until they stop tapping", which is a perfectly ordinary way to want this
    # — and it's what an EVENT-ended cycle looks like from here, because the
    # event doesn't end it on a clock, a watch does (see `stop_on!`).
    def over?(cycle, now: Time.current)
      ends = cycle["until_at"].presence
      return false if ends.nil?

      Time.zone.parse(ends.to_s).then { |at| at.present? && now >= at }
    rescue StandardError
      false
    end

    # The handle a stopping watch holds. It has to survive every block, because
    # the watch is armed once and the timer it eventually kills is the fifth one
    # in the chain, not the one that was running when it was set.
    def id_for(cycle) = cycle["cycle_id"].presence

    # Every live piece of one cycle: the block that's counting, the break, and
    # any card still waiting on a tap.
    def timers_for(user, cycle_id)
      Buddy::Timers.live_for(user).select { |t| id_for(cycle_for(t).to_h) == cycle_id }
    end

    def cards_for(user, cycle_id)
      scope = ByteAction.where(user_id: user.id, tool_name: TOOL_NAME).pending
      scope.select { |a| a.tool_input.to_h.dig(KEY, "cycle_id") == cycle_id }
    end

    # Every rhythm currently going, one entry each — a cycle spans many timer
    # rows and the person thinks of it as one thing, so the reminders list has
    # to as well.
    def live_cycles(user)
      seen = {}
      Buddy::Timers.live_for(user).each { |timer|
        cycle = cycle_for(timer)
        id    = id_for(cycle.to_h)
        next if id.nil? || seen.key?(id)

        seen[id] = { id: id, cycle: cycle, timer: timer }
      }
      seen.values
    end

    # The rhythm as a sentence, for a list row: "every 30 min, 10 min off,
    # until the print finishes".
    def describe(user, cycle)
      bits = ["every #{Buddy::Timers.humanize_seconds(cycle["seconds"])}"]
      bits << "#{Buddy::Timers.humanize_seconds(cycle["break_seconds"])} off" if cycle["break_seconds"].to_i.positive?
      bits << ending_phrase(user, cycle)
      bits.compact.join(", ")
    end

    def ending_phrase(user, cycle)
      stopper = stopper_for(user, id_for(cycle))
      return Buddy::WatchCondition.until_phrase(stopper.metadata.to_h["human_when"].presence || stopper.body) if stopper

      ends = cycle["until_at"].presence
      return nil if ends.nil?

      "until #{Time.zone.parse(ends.to_s).in_time_zone(user.timezone).strftime("%-l:%M %p").strip}"
    rescue StandardError
      nil
    end

    # `include_off` for the undo path only: switching the rhythm off cancels its
    # stopper too, so putting the rhythm back has to be able to find a stopper
    # that is currently switched off. Everywhere else wants the live one.
    def stopper_for(user, cycle_id, include_off: false)
      return nil if cycle_id.blank?

      scope = BuddyWatch.where(user_id: user.id, kind: :cancel, fired_at: nil)
      scope = scope.where(cancelled_at: nil) unless include_off
      scope.find { |w| w.cancels_cycle_id == cycle_id }
    end

    # Switched off from the reminders list. Same teardown the event does, minus
    # the announcement — they're looking at the list, so they can see it go.
    def cancel!(user, cycle_id)
      timers_for(user, cycle_id).each { |timer| Buddy::Timers.stop!(timer) }
      cards_for(user, cycle_id).each { |card| card.apply_decision!(value: "stopped", source: :user) }
      stopper_for(user, cycle_id)&.update!(cancelled_at: Time.current)
    end

    # Undo. The rhythm is a rule rather than a row, so putting it back means
    # starting the next block — read off whichever timer last carried it,
    # archived or not.
    def restart!(user, cycle_id, conversation)
      last  = user.timers.where.not(metadata: nil).order(id: :desc).find { |t| id_for(cycle_for(t).to_h) == cycle_id }
      cycle = cycle_for(last)
      return nil if cycle.nil?

      stopper_for(user, cycle_id, include_off: true)&.update!(cancelled_at: nil)
      start!(
        user:          user,
        conversation:  conversation,
        seconds:       cycle["seconds"],
        label:         cycle["label"].presence,
        break_seconds: cycle["break_seconds"],
        until_at:      cycle["until_at"],
        cycle_id:      cycle_id,
      )
    end

    # ---- starting one -------------------------------------------------------

    # The first block. Everything after it comes through `resume!`.
    # `anchor:` defaults to now, which is right for every block after the first —
    # they start on a TAP, and the last thing typed was however long ago the
    # previous block ran. Only the opening one, created inside the turn that
    # asked for the rhythm, backdates.
    def start!(user:, conversation:, seconds:, label: nil, break_seconds: nil, until_at: nil, cycle_id: nil, anchor: :now)
      Buddy::Timers.create!(
        user:         user,
        seconds:      seconds,
        label:        label,
        conversation: conversation,
        anchor:       anchor,
        metadata:     {
          KEY => {
            "cycle_id"      => cycle_id.presence || SecureRandom.uuid,
            "seconds"       => seconds.to_i,
            "break_seconds" => break_seconds.presence&.to_i,
            "until_at"      => until_at.presence&.then { |at| at.to_time.iso8601 },
            "label"         => label.to_s,
          }.compact,
        },
      )
    end

    # Arm the thing that ends it: a one-shot watch on the same conditions
    # `remind_when` runs on.
    #
    # "Until the print finishes" is not a time and must never be rounded into
    # one. A cycle ended this way has NO `until_at` at all — it goes round for
    # fifteen minutes or fifteen years, and stops when the thing happens.
    def stop_on!(timer, conversation, condition)
      cycle = cycle_for(timer)
      return nil if cycle.nil? || condition.nil?

      BuddyWatch.create!(
        user:              timer.user,
        byte_conversation: conversation,
        kind:              :cancel,
        trigger_scope:     condition.scope,
        listener:          condition.listener,
        match:             condition.match || {},
        body:              condition.human.to_s.presence || "That's done",
        one_shot:          true,
        metadata:          {
          "cancels_cycle" => id_for(cycle),
          "human_when"    => condition.human.to_s,
          # The same condition in the tense it will be READ in. See
          # WatchCondition.past_phrase - without it the sentence announcing the
          # thing was over said "when the print finishes - I've stopped the
          # check-ins."
          "human_past"    => condition.past.to_s,
        }.compact_blank,
      )
    end

    # The event happened. Take down the whole cycle — whichever block is
    # counting, its break, and any card still offering the next one.
    def stop_cycle!(user, cycle_id, conversation, said)
      live  = timers_for(user, cycle_id)
      cards = cards_for(user, cycle_id)
      return if live.empty? && cards.empty?

      live.each { |timer| Buddy::Timers.stop!(timer) }
      cards.each { |card| card.apply_decision!(value: "stopped", source: :system) }

      Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         "#{said.to_s.strip.presence || "That's done"}, so I've stopped the check-ins.",
        metadata:     { "kind" => "buddy", "source" => "timer_cycle", "cycle_id" => cycle_id },
        push_title:   "Stopped",
      )
    end

    # ---- the block ending ---------------------------------------------------

    # Called from Buddy::Timers.on_fired in place of the ordinary "time's up".
    def on_fired(timer, conversation)
      cycle = cycle_for(timer)
      return if cycle.nil?

      return finish!(timer, conversation, cycle) if over?(cycle)

      # Started BEFORE the card is posted, so the countdown they can see on the
      # hero is already running by the time they read the message telling them
      # to take it.
      rest = start_break(timer, conversation, cycle)
      offer!(timer, conversation, cycle, rest)
    end

    def start_break(timer, conversation, cycle)
      seconds = cycle["break_seconds"].to_i
      return nil unless seconds.positive?

      Buddy::Timers.create!(
        user:         timer.user,
        seconds:      seconds,
        label:        "Break",
        conversation: conversation,
      )
    rescue StandardError => e
      # A break that couldn't start is not a reason to withhold the button —
      # the block is over either way and they still need a way back in.
      Buddy::Errors.report(section: "timer_cycle.break", exception: e, user: timer.user)
      nil
    end

    def offer!(timer, conversation, cycle, rest)
      name    = conversation.buddy_name
      label   = cycle["label"].to_s.strip
      worked  = Buddy::Timers.humanize_seconds(cycle["seconds"])
      resting = (Buddy::Timers.humanize_seconds(cycle["break_seconds"]) if rest)

      message = Buddy::CompanionDelivery.deliver_plain(
        user:         timer.user,
        conversation: conversation,
        text:         fired_text(worked, label, resting),
        metadata:     { "kind" => "buddy", "source" => "timer_cycle", "timer_id" => timer.id },
        push_title:   label.present? ? "#{worked} on #{label}" : "#{worked} done",
      )

      attach_button!(timer.user, conversation, message, cycle, rest, worked)
    end

    def fired_text(worked, label, resting)
      done = label.present? ? "⏲ That's #{worked} on #{label}." : "⏲ That's #{worked}."
      return "#{done} Take #{resting} - I've started it. Tap below when you're ready for the next one." if resting

      "#{done} Tap below when you're ready for the next one."
    end

    # The card. `multi_select: false` and a single button, so it draws through
    # the ordinary action renderer with no client changes - one tap, and the
    # card settles into its decided state, which is also what stops a second
    # tap starting a second block.
    def attach_button!(user, conversation, message, cycle, rest, worked, button: nil)
      button ||= { "id" => 1, "label" => "Start the next #{worked}", "value" => RESUME, "variant" => "primary" }

      # Only ever one live button per cycle. Every card carries one so there is
      # always one to hand, which means the ones behind it have to stop being
      # tappable — two live cards is two ways to start a block, and the second
      # tap would start a second one on top of the first.
      retire_cards!(user, id_for(cycle))

      action = ByteAction.create!(
        user:              user,
        byte_conversation: conversation,
        byte_message:      message,
        kind:              :custom,
        tool_name:         TOOL_NAME,
        multi_select:      false,
        buttons:           [button],
        tool_input:        { KEY => cycle, "break_timer_id" => rest&.id }.compact,
        expires_at:        CARD_TTL.from_now,
      )

      message.update!(metadata: message.metadata.to_h.merge(
        "tool_name"         => TOOL_NAME,
        "action_request_id" => action.request_id,
        "action_kind"       => "custom",
        "action_state"      => "pending",
        "multi_select"      => false,
        "buttons"           => [button],
      ))
      Buddy::Timers.broadcast_chip(user, message.reload)
      action
    end

    # Hand somebody the button without a block having just ended: picking a
    # rhythm back up after it was dropped, or starting one on their say-so
    # rather than off a countdown they're in the middle of. No break timer,
    # because nothing just finished — the wait is for them to be ready.
    def offer_start!(user:, conversation:, cycle:, text:, push_title: nil)
      message = Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         text,
        metadata:     { "kind" => "buddy", "source" => "timer_cycle" },
        push_title:   push_title || text.to_s.truncate(60),
      )

      attach_button!(user, conversation, message, cycle, nil, Buddy::Timers.humanize_seconds(cycle["seconds"]))
    end

    # ---- the tap ------------------------------------------------------------

    # Start the next block. Called from ByteController#respond_action once the
    # decision is recorded, so a second tap can't reach here - the action is no
    # longer pending and the request 409s before this runs.
    def resume!(action)
      input = action.tool_input.to_h
      cycle = input[KEY]
      return nil unless cycle.is_a?(Hash)

      conversation = action.byte_conversation
      user         = action.user

      # However much of the break is left is theirs to give up. Leaving it
      # running means it fires partway into the block they just started and
      # announces a break that's already over.
      stop_break(user, input["break_timer_id"])

      if over?(cycle)
        finish!(nil, conversation, cycle, user: user)
        return nil
      end

      timer = start!(
        user:          user,
        conversation:  conversation,
        seconds:       cycle["seconds"],
        label:         cycle["label"].presence,
        break_seconds: cycle["break_seconds"],
        until_at:      cycle["until_at"],
        # Carried, not regenerated. A watch armed on the first block has to be
        # able to find the fifth one.
        cycle_id:      id_for(cycle),
      )
      chip!(user, conversation, cycle, timer)
      timer
    rescue StandardError => e
      Buddy::Errors.report(section: "timer_cycle.resume", exception: e, user: action&.user)
      nil
    end

    # Grey out every other card still offering something for this cycle.
    # `apply_decision!` is what the client reads to draw a card as settled, so
    # this is the same thing a tap does — just done for them.
    def retire_cards!(user, cycle_id)
      return if cycle_id.blank?

      cards_for(user, cycle_id).each { |card| card.apply_decision!(value: "superseded", source: :system) }
    end

    # The block that's counting right now. `timers_for` only matches rows
    # carrying this cycle's metadata, so the break — a plain timer — is never
    # what comes back.
    def block_timer(user, cycle_id)
      timers_for(user, cycle_id).first
    end

    # Offer a way out of the block that's running. Posted when a block STARTS,
    # so from the first second of it there is a button to hand.
    def offer_skip!(timer, conversation)
      cycle = cycle_for(timer)
      return nil if cycle.nil?

      user  = timer.user
      label = cycle["label"].to_s.strip
      dur   = Buddy::Timers.humanize_seconds(cycle["seconds"])

      message = Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         "#{dur}#{" on #{label}" if label.present?} is running.",
        metadata:     { "kind" => "buddy", "source" => "timer_cycle", "timer_id" => timer.id },
        push_title:   nil,
      )
      attach_button!(user, conversation, message, cycle, nil, dur, button: skip_button(cycle))
      message
    end

    def skip_button(cycle)
      rest = cycle["break_seconds"].to_i
      label = (
        if rest.positive?
          "Done early - start the #{Buddy::Timers.humanize_seconds(rest)}"
        else
          "Done early - next one"
        end
      )
      { "id" => 1, "label" => label, "value" => SKIP, "variant" => "secondary" }
    end

    # A tap on any cycle card. Which button it was decides what happens, so the
    # controller doesn't have to know there are two.
    def tapped!(action)
      value = action.decision.to_h["value"] || action.decision.to_h[:value]
      return skip!(action) if value.to_s == SKIP

      resume!(action)
    end

    # End the block where it stands and run the ordinary block-ending path — a
    # skipped block does exactly what a finished one does, which is how the
    # break still starts and the next card still appears.
    def skip!(action)
      cycle = action.tool_input.to_h[KEY]
      return nil unless cycle.is_a?(Hash)

      conversation = action.byte_conversation
      timer        = block_timer(action.user, id_for(cycle))
      return nil if timer.nil?

      Buddy::Timers.stop!(timer)
      on_fired(timer, conversation)
      timer
    rescue StandardError => e
      Buddy::Errors.report(section: "timer_cycle.skip", exception: e, user: action&.user)
      nil
    end

    def stop_break(user, timer_id)
      return if timer_id.blank?

      rest = user.timers.find_by(id: timer_id)
      Buddy::Timers.stop!(rest) if rest && rest.archived_at.nil?
    end

    def chip!(user, conversation, cycle, timer)
      label = cycle["label"].to_s.strip
      dur   = Buddy::Timers.humanize_seconds(cycle["seconds"])
      name  = conversation.buddy_name

      chip = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         "#{name} started the next #{dur}#{" on #{label}" if label.present?} ⏲",
        metadata:     {
          "kind"      => "buddy_activity",
          "tool_name" => "set_timer",
          "ok"        => true,
          "source"    => "timer_cycle",
          "timer_id"  => timer.id,
        },
        delivered_at: Time.current,
      )
      attach_button!(user, conversation, chip, cycle, nil, dur, button: skip_button(cycle))
      Buddy::Timers.broadcast_chip(user, chip.reload)
      chip
    end

    # ---- the end of the day -------------------------------------------------

    # No button on this one. The hour they named has arrived, and offering
    # another block past it is the thing they set an end time to avoid.
    def finish!(timer, conversation, cycle, user: nil)
      label = cycle["label"].to_s.strip
      who   = user || timer&.user
      ends  = Time.zone.parse(cycle["until_at"].to_s)&.strftime("%-l:%M %p")&.strip

      # Nothing is offered past the hour they named, so nothing should still be
      # tappable either.
      retire_cards!(who, id_for(cycle))

      Buddy::CompanionDelivery.deliver_plain(
        user:         who,
        conversation: conversation,
        text:         finished_text(label, ends),
        metadata:     { "kind" => "buddy", "source" => "timer_cycle", "timer_id" => timer&.id },
        push_title:   label.present? ? "#{label} - done for the day" : "That's the last block",
      )
    end

    def finished_text(label, ends)
      subject = label.present? ? " on #{label}" : ""
      return "⏲ That's #{ends} - you're done#{subject} for today. Nicely done 💛" if ends.present?

      "⏲ That's the last one#{subject}. Nicely done 💛"
    end
  end
end
