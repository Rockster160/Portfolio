# Wakes a sleeping Buddy and drains the messages that piled up while asleep.
# Scheduled by SleepGuard.sleep_until! for the wake time, and kicked
# immediately (perform_async) by maybe_wake! when a later request notices the
# window already passed. Idempotent: if the user is still asleep (the window
# was extended by a fresh usage-cap), it no-ops and the newer scheduled run
# handles the wake.
class BuddyWakeWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?
    return if Buddy::SleepGuard.sleeping?(user)

    Buddy::SleepGuard.wake!(user)

    # Drain oldest-first, each as its own turn. Flip to :pending before
    # delivery so a crash mid-drain leaves it retryable rather than stuck
    # :queued. deliver! re-sleeps Buddy if the Mac is still down, which
    # leaves the remaining queued turns held for the next wake.
    Buddy::SleepGuard.queued_messages(user).find_each do |message|
      # deliver! re-sleeps Buddy (on a fresh user record) if the Mac is still
      # down, so reload before each check to halt the drain and leave the
      # remaining turns :queued for the next wake rather than failing them.
      break if Buddy::SleepGuard.sleeping?(user.reload)

      message.update!(state: :pending)
      Buddy::TurnDispatcher.deliver!(message)
    end
  end
end
