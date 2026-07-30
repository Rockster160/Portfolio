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

    # There is no `deploy` trigger. A finished deploy announces itself as a
    # `monitor` broadcast on the `deploy:success` channel - that's what the
    # "Deploy Success" / "Run After Deploy Queue" Jil tasks listen on, and what
    # bin/wait_for_deploy subscribes to. But `remind_when` stores the watch under
    # scope `deploy`, and `monitor` isn't watchable, so dispatch bailed on the
    # only event that could ever satisfy it. Every deploy watch ever created sat
    # unfired (prod watch 4 waited two days through multiple deploys) while Buddy
    # had already promised the person a heads-up. Translating here is what makes
    # that promise keepable.
    #
    # Both shapes are accepted: the channel may carry the status itself
    # (`deploy:success`) or ride in the payload (`deploy` + status).
    def deploy_alias(scope, raw_data)
      return scope unless scope == "monitor"

      data    = raw_data.is_a?(Hash) ? raw_data.with_indifferent_access : {}
      channel = data[:channel].to_s.strip.downcase
      return scope unless channel.start_with?("deploy")

      succeeded = channel == "deploy:success" || data[:status].to_s.downcase == "success"
      succeeded ? "deploy" : scope
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

    def fire!(watch, payload={})
      if watch.notify_user_id
        fire_cross_user!(watch, payload)
      else
        fire_self!(watch)
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

    def fire_self!(watch)
      conversation = watch.byte_conversation
      user         = watch.user

      case watch.kind
      when "prompt"
        Buddy::CompanionDelivery.deliver_prompt(
          user:         user,
          conversation: conversation,
          seed:         watch.body,
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
