# Push one archive through to the mail that actually lives somewhere else.
#
# An `Email` here is a COPY. Domain mail arrives from S3 and Ardesian is the
# only client it has, so archiving the row is the whole job. Gmail mail is
# mirrored in by the job-mail watcher, and archiving the row tidies Ardesian
# while the message stays bold in the real inbox - which is the half this
# closes, by way of Mail.app on the desk Mac.
#
# OFF THE TAP on purpose. Mail's AppleScript talks to a GUI app that may be
# mid-sync, and a checkbox that hangs for twenty seconds is a broken checkbox.
# The Ardesian side is already saved by the time this runs, so the worst case
# here is that the message stays where it was - which is exactly where it was
# before the card existed.
class ArchiveMailWorker
  include Sidekiq::Worker

  # No retries. The Mac being asleep is the ordinary case, not a transient
  # fault, and re-queueing would have Sidekiq pounding a machine that is off
  # for the night to archive a mail nobody is waiting on. The next confirmation
  # takes its own turn.
  sidekiq_options retry: false

  def perform(email_id)
    email = Email.find_by(id: email_id)
    return if email.nil?

    # The Message-ID is how Mail finds it. Mail we generated an id for (see
    # Emails::StoreRaw) never had one on the wire, so nothing on the Mac can
    # match it and there is no point asking.
    mail_id = email.mail_id.to_s
    return if mail_id.blank? || mail_id.start_with?("no-message-id-")

    result = ByteLocal.archive_mail(message_id: mail_id)

    if result[:ok]
      PrettyLogger.info("[ArchiveMail] #{email.id} #{result[:state]} - #{result[:note]}")
    else
      # Logged rather than raised: see the class note. Nothing downstream reads
      # this and nobody is holding a turn on it.
      PrettyLogger.warn("[ArchiveMail] #{email.id} could not be archived: #{result[:error]}")
    end
  end
end
