# The side effects that must fire whenever an ActionEvent is added / changed /
# removed: the `:event` Jil trigger (so watches + automations react) and the
# live broadcast (so open views update). Deliberately NOT a model callback —
# backfills / bulk updates skip callbacks on purpose — so every code path that
# mutates a single event calls this instead. Jil::Methods::ActionEvent and all
# of Buddy's event tools (log/edit/delete + undo) go through here so they behave
# identically to a normal in-app event mutation.
class ActionEventNotifier
  # `action` is :added | :changed | :removed. `auth`/`auth_id` are the Jil audit
  # trail (Jil passes :trigger + task id; Buddy passes :buddy + user id).
  def self.notify(user, event, action, update_streak: true, auth: :trigger, auth_id: nil)
    attrs = { action: action }
    attrs[:changes] = event.saved_changes if action == :changed && event.saved_changes.present?
    ::Jil.trigger(user, :event, event.with_jil_attrs(attrs), auth: auth, auth_id: auth_id)

    reset_following_streak(event) if action == :removed

    # A SimpleFIN bank row may already be waiting for this event. The usual
    # order is alert-then-sync, but a charge synced before its alert was
    # categorised, a hand-edited event, or any backfill inverts it — and
    # without this the link would only ever happen in one direction. Exits
    # immediately for anything that is not a Transaction event.
    ::SimpleFin::EventMatcher.link_event(event) unless action == :removed

    ActionEventBroadcastWorker.perform_async(event.id, update_streak)
    event
  end

  # Removing an event breaks the action-streak chain for events of the same
  # name; re-anchor the next one so its streak recomputes.
  def self.reset_following_streak(removed_event)
    following = ::ActionEvent
      .where(user_id: removed_event.user_id)
      .ilike(name: removed_event.name)
      .where.not(id: removed_event.id)
      .where("timestamp > ?", removed_event.timestamp)
      .order(:timestamp)
      .first
    UpdateActionStreak.perform_async(following.id) if following.present?
  end
end
