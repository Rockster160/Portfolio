module Buddy
  # The condition-side counterpart to Buddy::ReminderFirer. Called once from
  # Jil::Executor.trigger for EVERY trigger the platform fires, so the first
  # thing it does is bail on any scope nothing is currently watching.
  #
  # That used to be a static list of the five scopes the named triggers use.
  # Custom listeners can name any scope, so the bail set is now derived from the
  # watches that actually exist - cached, because the alternative is an indexed
  # query on every tesla telemetry ping. The cache is busted whenever a watch is
  # created or settled (see BuddyWatch), so a brand-new watch is live at once
  # rather than up to the TTL later.
  module WatchMatcher
    module_function

    SCOPE_CACHE_KEY = "buddy:watch_scopes".freeze
    SCOPE_CACHE_TTL = 5.minutes

    def watched_scopes
      Rails.cache.fetch(SCOPE_CACHE_KEY, expires_in: SCOPE_CACHE_TTL) {
        BuddyWatch.active.distinct.pluck(:trigger_scope).compact
      }
    end

    def bust_scope_cache!
      Rails.cache.delete(SCOPE_CACHE_KEY)
    end

    def dispatch(user, scope, raw_data)
      return if user.nil?

      scope = deploy_alias(scope.to_s, raw_data)
      return unless watched_scopes.include?(scope)

      watches = BuddyWatch.active.where(user_id: user.id, trigger_scope: scope).to_a
      return if watches.empty?

      payload = normalize_payload(raw_data)
      payload = Buddy::DeploySignal.with_commit(user, payload) if scope == "deploy"
      watches.each { |watch| fire!(watch, payload) if watch.matches?(payload) }
    rescue => e
      # A watch failing to match must never take down the trigger it's
      # riding on (a chore completion, an arrival). Report and move on.
      Buddy::Errors.report(
        section:   "watch_matcher.dispatch",
        exception: e,
        user:      user,
        extra:     { scope: scope },
      )
    end

    # `remind_when` files a deploy watch under scope `deploy`, but almost
    # nothing actually fires that scope. A deploy announces itself as a
    # `monitor` broadcast, so it has to be translated here or the watch can
    # never be satisfied — prod watch 4 sat unfired for two days, and watch 10
    # slept through the 01:39 deploy on 07-31.
    #
    # What actually marks a deploy DONE is the app's own `startup` trigger: the
    # Jil task fires `monitor` with a bare `deploy: "success"` the moment the new
    # Rails boots, and that's what flips the Deploy ActionEvent to Success. It
    # carries no `id` and no `channel`, which is precisely what an earlier
    # version of this guard demanded — so the one signal that reliably arrives
    # was the one being dropped.
    #
    # (The workflow's own "Finish Deploy" curl posts to /jil/trigger/deploy, but
    # it fires while Puma is still restarting and comes back 502. Nothing
    # listens on that scope besides this, so success is single-sourced from
    # `startup` on purpose.)
    #
    # What a deploy payload MEANS - is this about one, did it work, which
    # commit was it - lives in Buddy::DeploySignal. Several shapes arrive for a
    # single deploy and none of them agree; this is only the routing.
    #
    # A FAILED deploy counts as finished: dropping it left a standing "ping me
    # on every deploy" watch silent on exactly the deploys worth hearing about,
    # and the person reads silence as "still going". Only a deploy that hasn't
    # landed yet (`deploy:start`) is ignored.
    def deploy_alias(scope, raw_data)
      return scope unless scope == "monitor"
      return scope unless Buddy::DeploySignal.about_deploy?(raw_data)

      Buddy::DeploySignal.outcome(raw_data) ? "deploy" : scope
    end

    def normalize_payload(raw)
      return raw if raw.is_a?(Hash)
      return {} unless raw.respond_to?(:execution_attrs)

      base = raw.respond_to?(:attributes) ? raw.attributes.symbolize_keys : {}
      base.merge(raw.execution_attrs || {})
    end

    # ONE real-world event can announce itself several times, and a repeating
    # watch has no way to tell that from the event happening again. Prod
    # 1320/1322/1323 were three notifications for a single deploy, 8 seconds
    # apart: the workflow's finish hook, then the app's own `startup` trigger
    # once per Puma worker as the new Rails came up.
    #
    # Nothing in the payloads ties them together - the startup trigger carries
    # no sha - so identity has to come from the clock. A deploy takes minutes,
    # so the same outcome twice inside this window is one deploy talking twice.
    #
    # Deliberately per-scope, and deliberately only deploy. Two chore
    # completions a second apart really are two, and collapsing those would
    # lose one.
    DEBOUNCE_WINDOWS = { "deploy" => 2.minutes }.freeze

    # What the window collapses, and what it must never collapse.
    #
    # This used to suppress everything inside the window on the theory that the
    # first signal was the workflow hook, the richest one. It frequently isn't:
    # `startup` fires the moment new Rails boots and usually wins the race.
    #
    # Prod 08-04 14:11 is what that costs. The deploy failed; Rails booted
    # anyway two seconds before cap died; `startup` reported success because
    # booting is all it can see; the workflow's failure hook - the only signal
    # that knew - landed inside the window and was dropped as a duplicate.
    # Byte said the deploy finished successfully and nothing ever corrected it.
    #
    # So the window collapses REPEATS, not contradictions. Three voices saying
    # success are one deploy; a failure after a success is the truth arriving
    # after a guess, and it has to get through.
    def debounced?(watch, payload={})
      window = DEBOUNCE_WINDOWS[watch.trigger_scope.to_s]
      return false if window.nil? || watch.last_fired_at.nil?
      return false if watch.last_fired_at <= window.ago

      signature_of(watch, payload) == watch.metadata.to_h["last_signature"]
    end

    # What makes two firings "the same news". For a deploy that's the OUTCOME -
    # not the sha, which only some of the signals carry, and not the payload,
    # which differs between them for one deploy.
    def signature_of(watch, payload)
      return nil unless watch.trigger_scope.to_s == "deploy"

      Buddy::DeploySignal.outcome(payload).to_s
    end

    # A second announcement moments after the first that says the OPPOSITE.
    # Marked as such because otherwise the thread carries two contradictory
    # lines two seconds apart with nothing to say which one is current - and
    # the one that's wrong is the one they read first.
    #
    # Deliberately not part of the template: this is about the pair of
    # messages, not about what either of them says, and it has to work on a
    # watch whose wording someone has since rewritten.
    def correcting?(watch, payload)
      window = DEBOUNCE_WINDOWS[watch.trigger_scope.to_s]
      return false if window.nil? || watch.last_fired_at.nil? || watch.last_fired_at <= window.ago

      previous = watch.metadata.to_h["last_signature"].to_s
      previous.present? && previous != signature_of(watch, payload)
    end

    def fire!(watch, payload={})
      return if debounced?(watch, payload)

      if watch.notify_user_id
        fire_cross_user!(watch, payload)
      else
        fire_self!(watch, payload)
      end

      # One-shot watches go terminal (fired_at) so `active` drops them and
      # they never re-fire. Repeating watches only stamp last_fired_at and
      # stay active for the next occurrence.
      stamp = { last_fired_at: Time.current }
      stamp[:fired_at] = Time.current if watch.one_shot
      # Remembered so the next signal inside the window can be told apart from
      # a repeat of this one.
      signature = signature_of(watch, payload)
      stamp[:metadata] = watch.metadata.to_h.merge("last_signature" => signature) if signature
      watch.update!(stamp)
    rescue => e
      Buddy::Errors.report(
        section:   "watch_matcher.fire",
        exception: e,
        user:      watch.user,
        extra:     { watch_id: watch.id },
      )
    end

    def fire_self!(watch, payload={})
      conversation = watch.byte_conversation
      user         = watch.user

      case watch.kind
      when "action"
        run_action!(watch)
      when "cancel"
        cancel_reminder!(watch)
      when "timer"
        start_timer!(watch)
      when "alarm"
        sound_alarm!(watch)
      when "prompt"
        if templated?(watch)
          announce!(watch, payload)
        else
          Buddy::CompanionDelivery.deliver_prompt(
            user:         user,
            conversation: conversation,
            seed:         self_seed(watch, payload),
            metadata:     { kind: "buddy_trigger", hidden: true, source: "watch", watch_id: watch.id },
          )
        end
      else
        said = Buddy::Template.render(
          watch.body, Buddy::WatchMessage.variables(watch, payload),
          user: user, conversation: conversation
        )
        Buddy::CompanionDelivery.deliver_plain(
          user:         user,
          conversation: conversation,
          text:         "Reminder: #{said}",
          metadata:     { kind: "buddy", source: "watch", watch_id: watch.id },
          push_title:   said,
        )
      end
    end

    # A repeating watch is a FEED, and a feed doesn't need composing.
    #
    # Every fire of one costs a whole model turn - prompt, tool schemas, the
    # lot - to produce a sentence whose entire content is "that happened
    # again". The Claude-list watch fired 64 times in one day, about a third of
    # the day's spend, and found 64 different ways to say another item landed
    # without ever naming the item.
    #
    # A one-shot is the opposite case and keeps its turn: it fires once, at a
    # moment that matters, often mid-conversation, and what it says is worth
    # writing.
    def templated?(watch)
      !watch.one_shot
    end

    def announce!(watch, payload)
      text = Buddy::WatchMessage.for(watch, payload)
      text = "Correction — #{text}" if correcting?(watch, payload)
      Buddy::CompanionDelivery.deliver_plain(
        user:         watch.user,
        conversation: watch.byte_conversation,
        text:         text,
        metadata:     { kind: "buddy", source: "watch", watch_id: watch.id },
        # Glyph and all: on a deploy it's the outcome, and the lock screen is
        # exactly where reading that first is worth something.
        push_title:   text,
      )
    end

    # An automation hanging off a condition. Deliberately no model anywhere on
    # this path: the scope is resolved when the watch is SET, so firing it is a
    # Jil trigger and a receipt chip. A delay hands off to a Sidekiq job rather
    # than sleeping, so the trigger that matched returns immediately and the
    # rest of the watches on that event still get their turn.
    def run_action!(watch)
      return BuddyWatchActionWorker.perform_in(watch.run_delay.seconds, watch.id) if watch.run_delay.positive?

      run_action_now!(watch)
    end

    # Fires the scope and leaves a trace. Shared with the delayed worker, which
    # re-checks the watch is still live before calling it.
    def run_action_now!(watch)
      scope = watch.run_scope
      return if scope.blank?

      ::Jil.trigger(watch.user, scope.to_sym, {}, auth: :buddy, auth_id: watch.user_id)
      action_chip(watch)
    end

    # A countdown instead of a sentence. The alarm at the end IS the message,
    # so nothing is said here beyond the chip that says a timer started - and
    # the label is the watch's own text, which is what puts a name on the
    # countdown chip rather than an anonymous clock.
    def start_timer!(watch)
      seconds = watch.timer_seconds
      return if seconds < 1

      # Anchored to now, not to whatever they last typed: a watch fires because
      # something HAPPENED, which has nothing to do with the conversation.
      Buddy::Timers.create!(
        user:         watch.user,
        seconds:      seconds,
        label:        watch.body.to_s.strip.presence,
        conversation: watch.byte_conversation,
      )
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "watch_matcher.start_timer",
        exception: e,
        user:      watch.user,
        extra:     { watch_id: watch.id },
      )
    end

    # Rings rather than counting down. Nothing is posted here: the alarm speaks
    # for itself when it goes off a second later (Buddy::Timers.on_fired), and
    # saying it twice would put the notification in the thread before the noise.
    # The thing they said to stop has happened, so stop it.
    #
    # It says so out loud rather than going quiet. Somebody who asked to be
    # nudged every half hour notices the nudges stopping either way, and the
    # difference between "it worked" and "it broke" is one sentence.
    def cancel_reminder!(watch)
      return cancel_cycle!(watch) if watch.cancels_cycle_id.present?

      reminder = BuddyReminder.find_by(id: watch.cancels_reminder_id)
      return if reminder.nil? || reminder.cancelled_at.present?

      reminder.update!(cancelled_at: Time.current)
      Buddy::CompanionDelivery.deliver_plain(
        user:         watch.user,
        conversation: watch.byte_conversation,
        text:         "#{watch.body.to_s.strip.presence || "That's done"} - I've stopped the check-ins.",
        metadata:     {
          "kind"        => "buddy",
          "source"      => "watch_cancel",
          "watch_id"    => watch.id,
          "reminder_id" => reminder.id,
        },
        push_title:   "Stopped: #{reminder.body.to_s.first(40)}",
      )
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "watch_matcher.cancel_reminder",
        exception: e,
        user:      watch.user,
        extra:     { watch_id: watch.id },
      )
    end

    # Same event, a cycle instead of a reminder: the block that's counting, its
    # break, and any card still offering the next one all come down together.
    def cancel_cycle!(watch)
      Buddy::TimerCycle.stop_cycle!(
        watch.user,
        watch.cancels_cycle_id,
        watch.byte_conversation,
        watch.body,
      )
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "watch_matcher.cancel_cycle",
        exception: e,
        user:      watch.user,
        extra:     { watch_id: watch.id },
      )
    end

    def sound_alarm!(watch)
      Buddy::Alarms.ring!(watch)
    rescue StandardError => e
      Buddy::Errors.report(
        section:   "watch_matcher.sound_alarm",
        exception: e,
        user:      watch.user,
        extra:     { watch_id: watch.id },
      )
    end

    def action_chip(watch)
      conversation = watch.byte_conversation
      return if conversation.nil?

      name = watch.run_task_name.presence || watch.run_scope
      when_ = watch.run_delay.positive? ? " (#{watch.run_delay}s after)" : ""
      msg = conversation.byte_messages.create!(
        user:         watch.user,
        direction:    :inbound,
        state:        :delivered,
        body:         "Fired **#{name}**#{when_} ⚡",
        metadata:     {
          "kind"      => "buddy_activity",
          "tool_name" => "trigger_jil_task",
          "ok"        => true,
          "source"    => "watch",
          "watch_id"  => watch.id,
          "detail"    => watch.metadata.to_h["human_when"].to_s.presence,
        }.compact,
        delivered_at: Time.current,
      )
      MonitorChannel.broadcast_to(watch.user, { id: :byte, channel: :byte, data: { kind: :message, message: msg.as_wire } })
    end

    # The stored body says what to tell them; for a deploy the OUTCOME is the
    # news, and "it finished" is a very different message from "it failed".
    # Without this the seed is the same either way and Buddy has to guess —
    # which, on a watch that now fires for failures too, means guessing wrong
    # half the time it matters.
    def self_seed(watch, payload)
      body = Buddy::Template.render(
        watch.body, Buddy::WatchMessage.variables(watch, payload),
        user: watch.user, conversation: watch.byte_conversation
      )
      return body unless watch.trigger_scope == "deploy"

      data    = Buddy::DeploySignal.indifferent(payload)
      outcome = Buddy::DeploySignal.outcome(data)
      return body if outcome.nil?

      sha  = data[:sha].to_s.strip.first(7).presence
      note = data[:message].to_s.strip.presence
      [
        outcome == :success ? "The deploy just finished successfully." : "The deploy just FAILED.",
        ("Commit #{sha}." if sha),
        ("What shipped: \"#{note}\"." if note),
        # Quoted and attributed, because the bare imperative ran straight into
        # the stored body and read as one instruction: "Tell them, in your own
        # voice: let you know the deploy finished" got answered with "Yep, sent
        # it along" (prod 1316) - the model took itself for the messenger and
        # reported back on the errand instead of doing it.
        "What they asked for was: \"#{body}\". Say it to them in your own voice.",
        ("Lead with the fact that it failed - that's the part they need." if outcome == :failed),
      ].compact.join(" ")
    end

    # A cross-user watch ("whenever I add to our Agenda, let Rocco know")
    # delivers to notify_user's companion, framed as coming from the owner.
    # A watch aimed at somebody ELSE is a message from whoever set it, waiting
    # on a condition instead of a clock. Same delivery as an immediate relay
    # and as a cross-user reminder (see Buddy::CompanionRelay#pass_along!):
    # bridged, so the recipient's copy carries the sender's companion and the
    # sender gets the copy that says it went.
    #
    # WatchMessage.for is what the self path already renders, so the wording -
    # template, glyph, appended detail - is identical whoever it reaches.
    def fire_cross_user!(watch, payload)
      recipient = watch.notify_user
      return if recipient.nil?

      Buddy::CompanionRelay.pass_along!(
        from:              watch.user,
        to:                recipient,
        text:              Buddy::WatchMessage.for(watch, payload),
        from_conversation: watch.byte_conversation,
      )
    end
  end
end
