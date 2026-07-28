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

      scope = scope.to_s
      return unless WATCHABLE_SCOPES.include?(scope)

      watches = BuddyWatch.active.where(user_id: user.id, trigger_scope: scope).to_a
      return if watches.empty?

      payload = raw_data.is_a?(Hash) ? raw_data : {}
      watches.each { |watch| fire!(watch) if watch.matches?(payload) }
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

    def fire!(watch)
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
  end
end
