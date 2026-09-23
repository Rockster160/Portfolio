# Hang a Gmail label on the mail a job-board card just filed, so it is easy to
# find and clear by hand.
#
# WHY NOT ARCHIVE IT, which is what this was for. Archiving in Gmail means
# removing the INBOX label, and Mail.app does not expose that - it keeps every
# Gmail message under All Mail and treats inbox membership as a label, so a
# `move` to the archive is a move to where the message already is. The first
# version did that, reported success, and left mail in the inbox looking filed.
# Adding a label is what Mail CAN do, so the labelling is automatic and the
# archiving stays his gesture.
#
# It no longer marks anything read either. Read-but-not-archived was the worst
# of the three states: an unread mail is bold and gets noticed, and marking it
# read hid the mail without filing it.
#
# Ardesian's own copy is still marked read and archived, synchronously, by the
# tool. That side is real - for domain mail Ardesian IS the client.
#
# OFF THE TAP on purpose. Mail's AppleScript talks to a GUI app that may be
# mid-sync, and a checkbox that hangs for twenty seconds is a broken checkbox.
class LabelMailWorker
  include Sidekiq::Worker

  # No retries. The Mac being asleep is the ordinary case, not a transient
  # fault, and re-queueing would have Sidekiq pounding a machine that is off for
  # the night to label a mail nobody is waiting on.
  sidekiq_options retry: false

  def perform(email_id)
    email = Email.find_by(id: email_id)
    return if email.nil?

    # The Message-ID is how Mail finds it. Mail we generated an id for (see
    # Emails::StoreRaw) never had one on the wire, so nothing on the Mac can
    # match it and there is no point asking.
    mail_id = email.mail_id.to_s
    return if mail_id.blank? || mail_id.start_with?("no-message-id-")

    result = ByteLocal.label_mail(message_id: mail_id)

    # `labelled` is the job done; `absent` is the mail already being dealt with.
    # Everything else is logged as a warning so it can be FOUND - the first
    # version of this reported a Gmail no-op as success and the mail sat in the
    # inbox for a day looking filed.
    done = %w[labelled absent].include?(result[:state].to_s)
    if result[:ok] && done
      PrettyLogger.info("[LabelMail] #{email.id} #{result[:state]} - #{result[:note]}")
    elsif result[:ok]
      PrettyLogger.warn("[LabelMail] #{email.id} NOT labelled (#{result[:state]}) - #{result[:note]}")
    else
      # Logged rather than raised: see the class note. Nothing downstream reads
      # this and nobody is holding a turn on it.
      PrettyLogger.warn("[LabelMail] #{email.id} could not be labelled: #{result[:error]}")
    end
  end
end
