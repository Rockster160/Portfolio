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
#
# PRODUCTION ONLY, and `already_ran?` cannot stand in for it. That guard asks
# whether a prompt was posted today in the database it is looking at, and a dev
# box has its own — so both say no and both run. The Mac is the shared piece:
# ByteLocal reaches it on localhost from a dev machine and by IP from
# production, they land on the same server, and it posts its report back to the
# ONE callback it is configured with, which is production. So a locally
# scheduled audit spends a full Claude session re-reading the day and publishes
# a second report into the production thread, carrying an `in_reply_to` that
# points at a prompt row only the dev database has (prod 4935, 5040 and 5100
# name 7133, 7152 and 7157). It landed in the right thread only because the two
# databases happen to agree on conversation 37.
#
# The local run comes from a scheduled Today finishing (Buddy::GPT::Turn
# #queue_daily_audit) and from the backstop cron, both of which arrive here, so
# here is where it stops. `ByteDailyAudit.kick!` deliberately does NOT go
# through this worker and still works by hand from a dev console.
class DailyAuditWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: false

  def perform
    return unless ::Rails.env.production?

    user = User.me
    return if user.nil?

    Rails.logger.info("[DailyAudit] #{ByteDailyAudit.run!(user)}")
  rescue StandardError => e
    Rails.logger.warn("[DailyAudit] failed: #{e.class}: #{e.message}")
    Buddy::Errors.report(section: "daily_audit_worker", exception: e, user: User.me) if defined?(Buddy::Errors)
  end
end
