class ReceiveEmailWorker
  include Sidekiq::Worker
  include ::Memoizable

  def perform(bucket, object_key, trigger=true)
    @bucket = bucket
    @object_key = object_key

    ::ActiveRecord::Base.transaction do
      @email = user.emails.find_by(mail_id: mail.message_id, timestamp: mail.date)
      @email ||= user.emails.create!(
        mail_id: mail.message_id.presence || "no-message-id-#{::SecureRandom.hex(4)}",
        timestamp: mail.date,
        direction: :inbound,
        inbound_mailboxes: internal_mailboxes,
        outbound_mailboxes: external_mailboxes,
        subject: mail.subject,
        blurb: text_content.gsub(/\s*\n\s*/, " ").first(500),
        has_attachments: mail.has_attachments?,
      ).tap { |created_email|
        warn_blank_message_id(created_email) if mail.message_id.blank?
      }

      @email.mail_blob.attach(stored_blob) if @email.mail_blob.blank?
    end

    return unless trigger

    # TODO: If using UUID, should specifically trigger ONLY that Task with the email as input.
    tasks = ::Jil.trigger_now(user, :email, @email)
    return if tasks.any?(&:stop_propagation?)
    @email.reload # Since Jil updates them out of scope
    return if @email.archived? # Task might have archived this. No need to do further logic if so.

    # TODO: Remove the below- these should be taken care of via tasks, including the Slack notifier
    if amazon_update?
      parse_amazon && @email.archive! # Auto archive Amazon emails
    end

    notify_slack if !@email.archived?
  end

  def amazon_update?
    ([
      "auto-confirm@amazon.com",
      "order-update@amazon.com",
      "shipment-tracking@amazon.com",
    ] & external_addresses).any?
  end

  def parse_amazon
    ::AmazonEmailParser.parse(@email)
  end

  💾(:content) { ::FileStorage.download(@object_key, bucket: @bucket) }
  💾(:mail) { ::Mail.new(content) }
  💾(:parser) { ::Emails::ParseMail.call(mail) }
  💾(:text_content) { parser.text_part }
  💾(:internal_mailboxes) { parser.to }
  💾(:external_mailboxes) { parser.from }
  💾(:internal_addresses) { internal_mailboxes.map { |address| address[:address] } }
  💾(:external_addresses) { external_mailboxes.map { |address| address[:address] } }
  💾(:stored_blob) {
    blob = ::ActiveStorage::Blob.find_by(key: @object_key)
    next blob if blob.present?

    checksum = ::Base64.encode64(::Digest::MD5.digest(content)).strip
    byte_size = content.bytesize
    filename = "email-#{SecureRandom.hex(4)}.eml"

    ::ActiveStorage::Blob.create_before_direct_upload!(
      filename: filename,
      byte_size: byte_size,
      checksum: checksum,
      content_type: "message/rfc822",
      key: @object_key,
      service_name: :s3_emails,
    )
  }
  💾(:user) {
    matching_user_id.present? ? ::User.find(matching_user_id) : ::User.me
  }
  💾(:matching_user_id) {
    internal_addresses.find { |address|
      personal, domain = address.split("@", 2)
      personal, ext = personal.split("+", 2)
      next unless domain.in?(::Email.registered_domains)

      user_id = ::User.ilike(username: personal).take&.id
      user_id ||= ::Task.find_by(uuid: ext)&.user_id if ::Jarvis::Regex.uuid?(ext)
      user_id ||= ::Task.find_by(uuid: personal)&.user_id if ::Jarvis::Regex.uuid?(personal)
      break user_id if user_id.present?
    }
  }

  def show_mailboxes(mailboxes)
    ::Emails::Normalizer.addresses_from_meta(mailboxes).then { |addresses|
      addresses.size == 1 ? addresses.first : "[#{addresses.join(" | ")}]"
    }
  end

  def notify_slack
    clean_text = text_content.to_s.gsub(/\n{3,}/, "\n\n")
    clean_text = clean_text.gsub(/[^\s]{30,}/, "blahblah")
    clean_text = clean_text.gsub(/(blahblah ?){2,}/, "blahblah")

    message_parts = []
    message_parts << "*#{show_mailboxes(internal_mailboxes)} received email from #{show_mailboxes(external_mailboxes)}*"
    message_parts << "_#{@email.subject}_"
    message_parts << "<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>"
    message_parts << ">>> #{clean_text.truncate(2000)}"
    SlackNotifier.notify(message_parts.join("\n"), channel: "#portfolio", username: "Mail-Bot", icon_emoji: ":mailbox:")
  end

  def warn_blank_message_id(email)
    desc = (
      if email&.persisted?
        [
          "*<https://ardesian.com/emails/#{email.id}|Email##{email.id}>*",
          "> #{email.subject}",
        ].join("\n")
      else
        [
          "*Failed to create!*",
          *email&.errors&.full_messages,
        ].join("\n * ")
      end
    )
    SlackNotifier.notify(
      desc + "\n" \
      "Message ID blank! `[#{mail.message_id.class}](#{mail.message_id.inspect})`\n" \
      "```ReceiveEmailWorker.new.perform(\"#{@bucket}\", \"#{@object_key}\")```",
    )
  end
end
