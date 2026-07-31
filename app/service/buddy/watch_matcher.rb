module Buddy
  # The condition-side counterpart to Buddy::ReminderFirer. Called once
  # from Jil::Executor.trigger for EVERY trigger the platform fires, so
  # the first thing it does is bail on any scope no watch can listen on -
  # that keeps the hot path (monitor, command, ...) to a single hash
  # lookup with zero DB work. Only the four watchable scopes ever touch
  # the DB, and only when the user has an active watch on that scope.
  module WatchMatcher
    module_function

    WATCHABLE_SCOPES = BuddyWatch::SCOPES

    def dispatch(user, scope, raw_data)
      return if user.nil?

      scope = deploy_alias(scope.to_s, raw_data)
      return unless WATCHABLE_SCOPES.include?(scope)

      watches = BuddyWatch.active.where(user_id: user.id, trigger_scope: scope).to_a
      return if watches.empty?

      payload = normalize_payload(raw_data)
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
    # Three payload shapes reach us, so read the outcome from any of them:
    #   { deploy: "success" }               — the startup trigger
    #   { id: "deploy", deploy: "failed" }  — the workflow's failure hook
    #   { channel: "deploy:success" }       — the cable re-broadcast
    #
    # A FAILED deploy counts as finished: dropping it left a standing "ping me
    # on every deploy" watch silent on exactly the deploys worth hearing about,
    # and the person reads silence as "still going". Only a deploy that hasn't
    # landed yet (`deploy:start`) is ignored.
    def deploy_alias(scope, raw_data)
      return scope unless scope == "monitor"

      data = raw_data.is_a?(Hash) ? raw_data.with_indifferent_access : {}
      return scope unless deploy_monitor?(data)

      deploy_outcome(data) ? "deploy" : scope
    end

    # Is this monitor broadcast about a deploy at all? A `deploy` key is enough
    # on its own — that's the startup trigger's whole payload.
    def deploy_monitor?(data)
      data.key?(:deploy) ||
        data[:id].to_s.strip.downcase == "deploy" ||
        data[:channel].to_s.strip.downcase.start_with?("deploy")
    end

    DEPLOY_OUTCOMES = {
      "success"   => :success,
      "succeeded" => :success,
      "finished"  => :success,
      "failed"    => :failed,
      "failure"   => :failed,
      "error"     => :failed,
    }.freeze

    # :success / :failed once a deploy is over, nil while it's still running.
    # Emitters disagree about where the outcome lives, so read all three:
    #   .github/workflows/deploy.yml posts `deploy=finished|failed|start`
    #   the cable re-broadcast names it in the channel (`deploy:success`)
    #   others put it in `status`
    def deploy_outcome(data)
      [
        data[:status],
        data[:deploy],
        data[:channel].to_s.split(":", 2).last,
      ].filter_map { |raw| DEPLOY_OUTCOMES[raw.to_s.strip.downcase] }.first
    end

    # Trigger payloads reach us in two shapes. Jil-built triggers (travel,
    # deploy) arrive as a plain Hash. But model-sourced triggers (chore
    # completions, events) arrive as the RECORD itself: `with_jil_attrs`
    # returns `self` with the real attrs stashed in `@execution_attrs`, and
    # `TriggerData.parse` passes ApplicationRecords through untouched. Flatten
    # both to one plain hash so `matches?` can read `action`/`chore_name`/
    # `name` uniformly. For a record we overlay execution_attrs (which carry
    # derived fields like `chore_name` and the `action` verb) on top of the
    # DB columns (which carry `name`), so either source of a key is visible.
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
    # so "finished" twice inside this window is one deploy talking twice.
    #
    # Deliberately per-scope, and deliberately only deploy. Two chore
    # completions a second apart really are two, and collapsing those would
    # lose one. Firing on the FIRST signal is also the right end to keep: it's
    # the workflow hook, the only one carrying the sha and commit message.
    DEBOUNCE_WINDOWS = { "deploy" => 2.minutes }.freeze

    def debounced?(watch)
      window = DEBOUNCE_WINDOWS[watch.trigger_scope.to_s]
      return false if window.nil? || watch.last_fired_at.nil?

      watch.last_fired_at > window.ago
    end

    def fire!(watch, payload={})
      return if debounced?(watch)

      if watch.notify_user_id
        fire_cross_user!(watch, payload)
      else
        fire_self!(watch, payload)
      end

      # One-shot watches go terminal (fired_at) so `active` drops them and
      # they never re-fire. Repeating watches only stamp last_fired_at and
      # stay active for the next occurrence.
      if watch.one_shot
        watch.update!(fired_at: Time.current, last_fired_at: Time.current)
      else
        watch.update!(last_fired_at: Time.current)
      end
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
      when "prompt"
        Buddy::CompanionDelivery.deliver_prompt(
          user:         user,
          conversation: conversation,
          seed:         self_seed(watch, payload),
          metadata:     { kind: "buddy_trigger", hidden: true, source: "watch", watch_id: watch.id },
        )
      else
        Buddy::CompanionDelivery.deliver_plain(
          user:         user,
          conversation: conversation,
          text:         "⏰ Reminder: #{watch.body}",
          metadata:     { kind: "buddy", source: "watch", watch_id: watch.id },
          push_title:   watch.body,
        )
      end
    end

    # The stored body says what to tell them; for a deploy the OUTCOME is the
    # news, and "it finished" is a very different message from "it failed".
    # Without this the seed is the same either way and Buddy has to guess —
    # which, on a watch that now fires for failures too, means guessing wrong
    # half the time it matters.
    def self_seed(watch, payload)
      return watch.body unless watch.trigger_scope == "deploy"

      data    = payload.is_a?(Hash) ? payload.with_indifferent_access : {}
      outcome = deploy_outcome(data)
      return watch.body if outcome.nil?

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
        "What they asked for was: \"#{watch.body}\". Say it to them in your own voice.",
        ("Lead with the fact that it failed - that's the part they need." if outcome == :failed),
      ].compact.join(" ")
    end

    # A cross-user watch ("whenever I add to our Agenda, let Rocco know")
    # delivers to notify_user's companion, framed as coming from the owner.
    def fire_cross_user!(watch, payload)
      notify_user  = watch.notify_user
      conversation = Buddy::CompanionRelay.conversation_for(notify_user)

      Buddy::CompanionDelivery.deliver_prompt(
        user:         notify_user,
        conversation: conversation,
        seed:         cross_user_seed(watch, payload),
        metadata:     { kind: "buddy_trigger", hidden: true, source: "watch_relay", watch_id: watch.id },
      )
    end

    def cross_user_seed(watch, payload)
      owner  = watch.user.first_name
      detail = payload.is_a?(Hash) ? payload[:name].to_s.strip.presence : nil
      base   = "#{owner} asked me to give #{watch.notify_user.first_name} a heads-up: #{watch.body}."
      base   = "#{base} (What changed: \"#{detail}\".)" if detail
      "#{base} Say it warmly, in your own voice - you're passing it along for #{owner}."
    end
  end
end
