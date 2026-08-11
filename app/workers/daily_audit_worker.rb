# Kicks off the nightly self-review (ByteDailyAudit) at 6am local, reviewing
# the day that just finished.
#
# The retry loop exists because this is the one scheduled job whose work happens
# on the Mac. `claude -p` runs there, so a sleeping machine means the turn can't
# happen at all — and a message posted at a sleeping Mac isn't deferred, it's a
# `failed` bubble sitting in the thread. So the Mac is checked BEFORE anything
# is posted, and a miss becomes "try again in a bit" rather than a broken
# report.
#
# Sidekiq's own retry is off: it would re-run `perform` with no idea how long
# it had been waiting or how many times it had tried, and a job that reschedules
# itself needs to own both.
class DailyAuditWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  RETRY_EVERY  = 20.minutes
  MAX_ATTEMPTS = 12 # ~4 hours of trying, so a Mac woken mid-morning still lands

  def perform(attempt=0)
    user = User.me
    return if user.nil?

    if ByteLocal.awake?
      result = ByteDailyAudit.run!(user)
      Rails.logger.info("[DailyAudit] #{result} on attempt #{attempt}")
      return
    end

    if attempt + 1 >= MAX_ATTEMPTS
      Rails.logger.warn("[DailyAudit] gave up after #{MAX_ATTEMPTS} attempts - Mac never answered")
      report_unreachable(user)
      return
    end

    Rails.logger.info("[DailyAudit] Mac asleep, retrying in #{RETRY_EVERY.inspect} (attempt #{attempt + 1})")
    self.class.perform_in(RETRY_EVERY, attempt + 1)
  rescue StandardError => e
    Rails.logger.warn("[DailyAudit] failed: #{e.class}: #{e.message}")
    Buddy::Errors.report(section: "daily_audit_worker", exception: e, user: User.me) if defined?(Buddy::Errors)
  end

  private

  # Say so in the thread rather than only in the log. A missing report reads
  # exactly like a quiet day, and those are the two things it most matters to
  # tell apart.
  def report_unreachable(user)
    convo = ByteDailyAudit.conversation(user)
    convo.byte_messages.create!(
      user:      user,
      direction: :inbound,
      state:     :delivered,
      body:      "_No audit today - the Mac never came up. Nothing was reviewed; this is not a quiet day._",
      metadata:  { "kind" => "system", "daily_audit_skipped" => true },
    )
  rescue StandardError => e
    Rails.logger.warn("[DailyAudit] could not post the unreachable notice: #{e.class}: #{e.message}")
  end
end
