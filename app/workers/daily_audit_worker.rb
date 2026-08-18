# Kicks off the daily self-review (ByteDailyAudit), covering the 24 hours that
# just finished (see ByteDailyAudit#window).
#
# Enqueued the moment the morning Today briefing finishes writing
# (Buddy::GPT::Turn#queue_daily_audit), so the report lands directly under it:
# one is what's coming, the other is what broke. The briefing moves with the
# person's schedule, so no fixed hour could follow it.
#
# The cron entry of the same name is only the BACKSTOP, for the day Today never
# came at all. It runs once, and on an ordinary day it does nothing, because
# `already_ran?` inside run! has already seen this morning's report.
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
