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

    # Every Transaction event gets a bank_transactions row, so that table is
    # the only one anything has to query. It links to a SimpleFIN row already
    # waiting for it, and creates one when none is — a purchase is then visible
    # and categorized the moment the alert arrives, rather than whenever the
    # bank next clears and reports it. Exits immediately for anything that is
    # not a Transaction event.
    touched = (
      if action == :removed
        ::SimpleFin::EventTransaction.forget(event)
      else
        ::SimpleFin::EventTransaction.sync(event)
      end
    )

    # The published balance counts everything since the bank's last snapshot,
    # so a transaction alert changes it the moment it lands — which is the
    # point, and is hours before SimpleFIN would have said anything. Skipped
    # for every event that is not a Transaction: both calls above answer blank
    # for those.
    republish_balance if touched.present?

    # An alert is the only real-time signal there is — SimpleFIN is polled and
    # can be a day behind. If this charge would tip the dashboard's floored
    # balance into a different thousand, go and fetch the new figure rather
    # than showing a confidently wrong one until the next scheduled sync.
    # No-ops for anything that isn't a boundary-crossing checking charge.
    ::SimpleFin::BalanceWatch.consider(event) if action == :added

    ActionEventBroadcastWorker.perform_async(event.id, update_streak)
    event
  end

  # Never at the cost of the event itself. Everything here is already stored by
  # the time this runs; a cache write or a Jil re-render that fails must not
  # take the notification — or the alert that produced it — down with it.
  def self.republish_balance
    ::SimpleFin::DashboardCache.refresh!
  rescue ::StandardError => e
    ::Rails.logger.warn("[ActionEventNotifier] balance refresh failed: #{e.message}")
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
