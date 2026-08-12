# Kicks off the daily self-review (ByteDailyAudit) at 6am local, covering the
# 24 hours that just finished (see ByteDailyAudit#window).
#
# The time is set by the cron entry, not here — `daily_6am` in sidekiq_cron.rb.
# Don't restate it anywhere else: this comment said 6am while the job ran at
# 10pm and the wrong one was believed, which is how a report that had already
# landed got read as a job that never ran.
#
# Sidekiq's own retry is off. The work is a Claude turn that streams back into
# the thread over several minutes, so a retry would post a second prompt on top
# of a run that is still going.
class DailyAuditWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  def perform
    user = User.me
    return if user.nil?

    Rails.logger.info("[DailyAudit] #{ByteDailyAudit.run!(user)}")
  rescue StandardError => e
    Rails.logger.warn("[DailyAudit] failed: #{e.class}: #{e.message}")
    Buddy::Errors.report(section: "daily_audit_worker", exception: e, user: User.me) if defined?(Buddy::Errors)
  end
end
