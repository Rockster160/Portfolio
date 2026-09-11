module Emails
  # A raw RFC822 message from outside the registered domains, kept the same way
  # domain mail is: one Email row, and the bytes themselves on S3 behind
  # `mail_blob`.
  #
  # The Mac watcher reads the personal Gmail, and what it finds used to reach
  # Rails as a few thousand characters of flattened plaintext in a webhook
  # field. That is enough to say what happened and not enough to keep. The note
  # got a trimmed copy, the message itself stayed on the Mac, and there was
  # nothing to point at — so a beat logged off Gmail was strictly poorer than
  # the same beat logged off ardesian, where `add_job_note` picks up the date,
  # the sender and a link back purely by being handed an `email_id`.
  #
  # Deliberately NOT ReceiveEmailWorker. That path is for mail nobody has seen:
  # it fires the `email` Jil trigger, runs the Amazon and USPS parsers, posts to
  # Slack and hands the row to job triage. This mail has already been read in
  # Gmail and already been classified on the Mac, and running any of it again
  # would fire every automation hanging off the person's own inbox a second
  # time, days after they dealt with the mail themselves.
  module StoreRaw
    module_function

    # Big enough for anything worth keeping to refer back to; small enough that
    # a mail carrying a deck or a signed PDF doesn't ride through a webhook.
    # Over it there is simply no row — which is what happened before this
    # existed, and the offer still works from the plaintext.
    MAX_BYTES = 4.megabytes

    # `raw` is the message as the sender wrote it, headers and all. Returns the
    # Email, or nil when there was nothing usable — every caller treats a nil as
    # "carry on without one" rather than as a failure, because a beat announced
    # without its paperwork is worth far more than a beat not announced.
    def call(user:, raw:, direction: :inbound, occurred_at: nil, triage: {})
      return nil if user.blank? || raw.blank?
      return nil if raw.bytesize > MAX_BYTES

      mail   = ::Mail.new(raw)
      parser = ::Emails::ParseMail.call(mail)
      stamp  = mail.date&.to_time || occurred_at || Time.current

      # Same mail, twice: a Gmail label makes a second row in Mail.app's index,
      # and the watcher's own dedupe is per-run rather than forever.
      email = user.emails.find_by(mail_id: message_id(parser, stamp))
      email ||= create(user, parser, mail, stamp, direction, triage)
      attach(email, raw)
      email
    rescue StandardError => e
      Rails.logger.warn("[Emails::StoreRaw] could not store #{raw.to_s.bytesize}B: #{e.class}: #{e.message}")
      nil
    end

    def create(user, parser, mail, stamp, direction, triage)
      # `inbound_mailboxes` is US and `outbound_mailboxes` is THEM — the names
      # describe the direction mail travelled to reach the person, not the
      # column. On something they SENT, the two swap over.
      ours, theirs = (
        direction.to_sym == :outbound ? [parser.from, parser.to] : [parser.to, parser.from]
      )

      user.emails.create!(
        mail_id:            message_id(parser, stamp),
        timestamp:          stamp,
        direction:          direction,
        inbound_mailboxes:  ours,
        outbound_mailboxes: theirs,
        subject:            mail.subject.to_s,
        blurb:              parser.condensed_text.to_s.first(500),
        has_attachments:    mail.has_attachments?,
        job_triage:         triage.presence || {},
        # They have already read it, in Gmail, days before this row existed.
        # Landing as unread would put a number on the app's mail badge for
        # something already dealt with somewhere else.
        read_at:            Time.current,
      )
    end

    # Attached separately from creation so a row that already exists — the same
    # mail arriving under a second Gmail label — picks up the bytes if the first
    # attempt at them failed.
    def attach(email, raw)
      return if email.blank? || email.mail_blob.attached?

      email.mail_blob.attach(
        io:           StringIO.new(raw),
        filename:     "email-#{SecureRandom.hex(4)}.eml",
        content_type: "message/rfc822",
      )
    end

    # A Message-ID is what makes two copies of one mail the same mail. Mail that
    # arrives without one gets a stable stand-in rather than a random id, so a
    # retry doesn't make a second row for it.
    def message_id(parser, stamp)
      parser.message_id.presence || "no-message-id-#{stamp.to_i}"
    end
  end
end
