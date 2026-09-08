# Asks whether one inbound email is a beat in the job search, shortly after it
# lands.
#
# Out here rather than inline in ReceiveEmailWorker for the reason every other
# model call in this codebase is: it costs a call, and nothing about accepting
# an email should wait on one. `low` queue because nothing is blocked on the
# answer and a backlog of these must never delay a reminder firing.
#
# Takes an id rather than a record so a retry re-reads current state, and gives
# up quietly on anything since deleted.
class JobMailTriageWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  def perform(email_id)
    email = Email.find_by(id: email_id)
    return if email.nil?

    Emails::JobTriage.triage!(email)
  end
end
