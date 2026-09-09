module Buddy
  # A countdown that comes back and ASKS, instead of announcing that time is up
  # and leaving nothing behind: "did you rotate it, is it finished, or drop it".
  #
  # The laundry is the archetype and the reason it exists. Pressing the laundry
  # button used to call `Custom.RemindTimer`, which parked a Schedule row nobody
  # could see and, an hour and a quarter later, put "Rotate Laundry" on the TODO
  # list. Nothing counted down anywhere, cancelling meant finding a schedule id,
  # and pressing the button twice made a second one.
  #
  # Here it is an ordinary Buddy timer carrying a `rotation` key in its metadata,
  # so the countdown is on the hero, a swipe cancels it, and the fire is a card
  # with three buttons on it:
  #
  #   Again  - the loop goes round: this timer stops and an identical one starts.
  #   Done   - the loop ends, and whatever follow-up was configured goes on a list.
  #   Skip   - the loop ends and nothing else happens.
  #
  # `key` is the identity that survives a round, because every round is a NEW
  # timer row (same reason as Buddy::TimerCycle: a fresh row through
  # Buddy::Timers.create! gets the atomic start and the :created broadcast, and
  # re-arming a spent one has too many half-states to get right). It is also what
  # makes the physical button idempotent — `start!` on a key with a rotation
  # already live IS the Again button, card and all.
  module RotationTimer
    module_function

    TOOL_NAME = "buddy_rotation".freeze
    KEY       = "rotation".freeze

    AGAIN = "again".freeze
    DONE  = "done".freeze
    SKIP  = "skip".freeze

    # Every outcome fires this, so a Jil task can hang anything else off a round
    # ending without a deploy. Payload: key, choice, round, label.
    TRIGGER_SCOPE = :rotation

    # A load left in the washer overnight is exactly the case this is for, so the
    # card has to still be tappable in the morning. Longer than TimerCycle's six
    # hours, which is bounded by a working day.
    CARD_TTL = 12.hours

    DEFAULT_AGAIN = "Again".freeze

    # ---- reading one --------------------------------------------------------

    def spec_for(timer)
      meta = timer&.metadata
      return nil unless meta.is_a?(::Hash)

      spec = meta[KEY]
      spec.is_a?(::Hash) ? spec : nil
    end

    def rotation?(timer)
      spec_for(timer).present?
    end

    # The timer counting (or ringing) for this key. Scoped through
    # `Buddy::Timers.live_for` rather than a jsonb query so an archived or
    # never-started row can never come back as the live one.
    def live_timer(user, key)
      return nil if key.blank?

      Buddy::Timers.live_for(user).find { |timer| spec_for(timer).to_h["key"].to_s == key.to_s }
    end

    def cards_for(user, key)
      return [] if key.blank?

      scope = ByteAction.where(user_id: user.id, tool_name: TOOL_NAME).pending
      scope.select { |action| action.tool_input.to_h.dig(KEY, "key").to_s == key.to_s }
    end

    # Whatever this key last knew about itself: the live timer first, then a card
    # still waiting on a tap. A ring nobody answered leaves only the card, and
    # the round count has to survive that or every unanswered round reads as the
    # first one.
    def last_spec(user, key)
      live = spec_for(live_timer(user, key))
      return live if live.present?

      cards_for(user, key).first&.tool_input.to_h[KEY]
    end

    # ---- starting one -------------------------------------------------------

    # Start the loop, or send it round again. The two are the same call on
    # purpose: the button on the wall has no idea whether a timer is already
    # running, and "press it again because I rotated it" is the whole point.
    #
    # A question still on screen is ANSWERED by the press — they went and did the
    # thing rather than tapping about it — so its card settles as Again rather
    # than sitting there tappable next to a countdown that already restarted.
    # `follow_up` is `{ item:, list: }` — the two travel together because
    # neither means anything alone: an item with no list is a follow-up that
    # silently never lands, and a list with no item is nothing at all.
    def start!(user:, key:, label:, seconds:, again: nil, follow_up: nil, conversation: nil, anchor: :now)
      conversation ||= Buddy::CompanionRelay.conversation_for(user)
      return nil if conversation.nil?

      leaves = follow_up.to_h.symbolize_keys
      item   = leaves[:item]
      list   = leaves[:list]

      previous = live_timer(user, key)
      before   = last_spec(user, key).to_h
      round    = before["round"].to_i + 1

      # A restart inherits whatever it didn't mention. The button on the wall
      # sends the lot every time, but a spoken "start the laundry one again"
      # carries a label and an interval and nothing else - and blanking the
      # follow-up on that would quietly drop the item they asked to be left
      # behind, without a word either way. Nil means UNSAID, not "clear it".
      again = again.presence || before["again"]
      item  = item.presence  || before["item"]
      list  = list.presence  || before["list"]

      retire_cards!(user, key, value: AGAIN)
      Buddy::Timers.stop!(previous) if previous

      timer = Buddy::Timers.create!(
        user:         user,
        seconds:      seconds,
        label:        label,
        conversation: conversation,
        anchor:       anchor,
        metadata:     {
          KEY => {
            "key"     => key.to_s,
            "label"   => label.to_s,
            "seconds" => seconds.to_i,
            "again"   => again.presence,
            "item"    => item.presence,
            "list"    => list.presence,
            "round"   => round,
          }.compact,
        },
      )
      chip!(user, conversation, timer, round: round)
      timer
    end

    # Settle every card still open on this key. `apply_decision!` is what the
    # client reads to draw one as spent, so this is the same thing a tap does —
    # and because it only touches PENDING actions, the card whose own tap led
    # here is already decided and passes straight through.
    def retire_cards!(user, key, value:)
      cards_for(user, key).each { |card| card.apply_decision!(value: value, source: :user) }
    end

    # The countdown was taken away rather than answered - a swipe on the chip,
    # `cancel_timer`, or the tool. Called from Buddy::Timers.stop!, which every
    # one of those goes through.
    #
    # A rotation rings and WAITS, so a cancel most often arrives with the card
    # already up; leaving it there is a loop somebody thinks they switched off,
    # still offering to go round again. `retire_cards!` only touches pending
    # ones, so the restart path - which settles as Again first, then stops the
    # old timer - passes straight through here untouched.
    def abandoned!(timer)
      spec = spec_for(timer)
      return nil if spec.nil?

      retire_cards!(timer.user, spec["key"], value: SKIP)
    end

    # ---- the fire -----------------------------------------------------------

    # Called from Buddy::Timers.on_fired in place of the ordinary "time's up".
    #
    # The timer is deliberately left RINGING (fired, unconfirmed): this is a
    # countdown they set and the noise is the point, unlike a wait. Answering the
    # card is what stops it — see `tapped!`.
    def on_fired(timer, conversation)
      spec = spec_for(timer)
      return nil if spec.nil?

      action = ByteAction.create_request!(
        user:            timer.user,
        conversation:    conversation,
        kind:            :question,
        tool_name:       TOOL_NAME,
        title:           card_title(spec),
        body:            body_for(spec),
        buttons:         buttons_for(spec),
        tool_input:      { KEY => spec },
        multi_select:    false,
        timeout_seconds: CARD_TTL,
      )
      notify!(timer.user, action, title: card_title(spec))
      action
    end

    def card_title(spec)
      spec["label"].to_s.presence || "Timer"
    end

    def body_for(spec)
      "That's #{Buddy::Timers.humanize_seconds(spec["seconds"])}."
    end

    def buttons_for(spec)
      item = spec["item"].to_s
      list = spec["list"].to_s
      done = { "id" => 2, "label" => "Done", "value" => DONE }
      done["description"] = "Puts #{item} on #{list}" if item.present? && list.present?

      [
        { "id" => 1, "label" => spec["again"].to_s.presence || DEFAULT_AGAIN, "value" => AGAIN, "variant" => "primary" },
        done,
        { "id" => 3, "label" => "Skip", "value" => SKIP },
      ]
    end

    # A card posted off a countdown is a question nobody was told about — they
    # were in another room, which is where you are when the washer finishes.
    # Same shape as Buddy::PromptDelivery.notify!, including the kiosk rule: a
    # question on the wall is answered by tapping the wall.
    def notify!(user, action, title:)
      message = action&.byte_message
      return if message.nil? || message.byte_conversation&.kiosk?

      WebPushNotifications.send_to_byte(
        title: title.to_s.truncate(160),
        tag:   "byte-#{message.id}",
        users: [user],
      )
    rescue StandardError => e
      Buddy::Errors.report(section: "rotation_timer.notify", exception: e, user: user)
    end

    # ---- the tap ------------------------------------------------------------

    # Called from ByteController#respond_action once the decision is recorded, so
    # a second tap can't reach here — the action has stopped being pending and
    # the request 409s before this runs.
    def tapped!(action)
      spec = action.tool_input.to_h[KEY]
      return nil unless spec.is_a?(::Hash)

      user         = action.user
      conversation = action.byte_conversation
      choice       = action.decision.to_h["value"].to_s
      key          = spec["key"].to_s

      if choice == AGAIN
        start!(
          user:         user,
          key:          key,
          label:        spec["label"],
          seconds:      spec["seconds"],
          again:        spec["again"],
          follow_up:    { item: spec["item"], list: spec["list"] },
          conversation: conversation,
        )
      else
        # The chip is still ringing at 0:00 — answering the question IS the
        # acknowledgement, and leaving it there would mean dismissing the same
        # thing twice. Already gone if they tapped the ringing chip first.
        ringing = live_timer(user, key)
        Buddy::Timers.stop!(ringing) if ringing
        finish!(user, conversation, spec) if choice == DONE
      end

      fire_trigger(user, spec, choice)
      choice
    rescue StandardError => e
      Buddy::Errors.report(section: "rotation_timer.tapped", exception: e, user: action&.user)
      nil
    end

    # The follow-up the loop was holding: whatever comes AFTER the rotating is
    # over. Configured rather than assumed, so a rotation with nothing to leave
    # behind just ends.
    def finish!(user, conversation, spec)
      list_name = spec["list"].to_s
      item      = spec["item"].to_s
      return nil if list_name.blank? || item.blank?

      list = ::List.by_name_for_user(list_name, user)
      return nil if list.nil?

      list.add(item)
      chip(user, conversation, "#{conversation.buddy_name} put #{item} on #{list.name} ✓")
    end

    def fire_trigger(user, spec, choice)
      data = {
        key:    spec["key"].to_s,
        choice: choice.to_s,
        round:  spec["round"].to_i,
        label:  spec["label"].to_s,
      }
      ::Jil.trigger(user, TRIGGER_SCOPE, data, auth: :trigger)
    rescue StandardError => e
      Buddy::Errors.report(section: "rotation_timer.trigger", exception: e, user: user)
    end

    # ---- receipts -----------------------------------------------------------

    # A press on the wall produces nothing on screen by itself, so the thread is
    # the only place it's visible. Round 1 reads as a start, everything after it
    # as going round again — which is also the difference between "I set this"
    # and "that got done, here's the next one".
    def chip!(user, conversation, timer, round:)
      name  = conversation.buddy_name
      label = spec_for(timer).to_h["label"].to_s
      dur   = Buddy::Timers.humanize_seconds(timer.duration_ms.to_i / 1000)
      verb  = round > 1 ? "restarted" : "started"

      chip(user, conversation, "#{name} #{verb} the #{dur} #{label} timer ⏲", timer_id: timer.id)
    end

    def chip(user, conversation, text, timer_id: nil)
      message = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         text,
        metadata:     {
          "kind"      => "buddy_activity",
          "tool_name" => TOOL_NAME,
          "ok"        => true,
          "source"    => "rotation",
          "timer_id"  => timer_id,
        }.compact,
        delivered_at: Time.current,
      )
      Buddy::Timers.broadcast_chip(user, message)
      message
    end
  end
end
