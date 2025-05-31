class ReceiveEmailWorker
  include Sidekiq::Worker
  include ::Memoizable

  def perform(bucket, object_key)
    @bucket = bucket
    @object_key = object_key
    require "mail"

    ::ActiveRecord::Base.transaction do
      @email = ::Email.create!(
        user_id: matching_user_id || ::User.me.id,
        timestamp: mail.date,
        direction: :inbound,
        inbound_mailboxes: mail.to_addresses.map(&:to_s),
        outbound_mailboxes: [mail.from_address.to_s],
        subject: mail.subject,
        blurb: text_content.first(500),
        has_attachments: mail.has_attachments?,
      )

      @email.mail_blob.attach(stored_blob)
    end

    # tasks = ::Jil.trigger_now(user_id, :email, legacy_serialize)
    # return if tasks.any?(&:stop_propagation?)
    # reload # Since Jil updates them out of scope
    # return if archived? # Task might have archived this. No need to do further logic if so.

    # # TODO: Remove the below- these should be taken care of via tasks, including the Slack notifier

    blacklist = [
      "LV Bag",
      "Louis Vuitton"
    ]

    if reolink?
      parse_reolink && @email.archive!
      # && @email.destroy # Should trigger the file to be deleted as well
    elsif amazon_update?
      parse_amazon && @email.archive! # Auto archive Amazon emails
    elsif blacklist.any? { |bad| text_content.include?(bad) }
      @email.archive!
    end

    notify_slack if !@email.archived?
  end

  def reolink?
    mail.from_address.display_name == "Reolink"
  end

  def parse_reolink
    _, location, detection = mail.subject.match(/\[?(\w+)\]? has detected (?:an? )?(\w+)/i)&.to_a
    return unless location && detection

    camera = ::MeCache.get(:camera)
    loc = camera[location.to_sym] || {}
    loc.merge!(at: mail.date.to_f, type: detection)

    camera[:states] = [:Doorbell, :Driveway, :Backyard, :Storage].map { |key|
      at = camera.dig(key, :at)
      next "?" unless at

      ::EventAnalyzer.duration(::Time.current.to_f - at.to_f, 1)
    }.join(" ")

    ::MeCache.set(:camera, camera)
  end

  def amazon_update?
    ([
      "auto-confirm@amazon.com",
      "order-update@amazon.com",
      "shipment-tracking@amazon.com",
    ] & from_addresses).any?
  end

  def parse_amazon
    ::AmazonEmailParser.parse(@email)
  end

  💾(:content) { ::FileStorage.download(@object_key, bucket: @bucket) }
  💾(:mail) { ::Mail.new(content) }
  💾(:text_content) {
    clean_content(mail.text_part&.body&.decoded.presence) || clean_content(content, parse_text: true)
  }
  💾(:to_addresses) { [mail.to].flatten.compact }
  💾(:from_addresses) { [mail.from].flatten.compact }
  💾(:stored_blob) {
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
  💾(:matching_user_id) {
    to_addresses.find { |address|
      personal, domain = address.split("@", 2)
      personal, ext = personal.split("+", 2)
      next unless domain.in?(::Email.registered_domains)

      user_id = ::User.ilike(username: personal).take&.id
      break user_id if user_id.present?

      next unless ::Jarvis::Regex.uuid?(personal)
      ::Task.find_by(uuid: personal)&.user_id
    }
  }

  def clean_content(raw_html, parse_text: false)
    return unless raw_html.present?

    html = raw_html.encode("UTF-8", invalid: :replace, undef: :replace, replace: "", universal_newline: true).gsub(/\P{ASCII}/, "")
    return html unless parse_text

    parser = ::Nokogiri::HTML(html, nil, ::Encoding::UTF_8.to_s)
    parser.xpath("//script")&.remove
    parser.xpath("//style")&.remove
    parser.xpath("//text()").map(&:text).join(" ").squish
  end

  def notify_slack
    clean_text = text_content.to_s.gsub(/\n{3,}/, "\n\n")
    clean_text = clean_text.gsub(/\b= \b/, "")
    clean_text = clean_text.gsub(/[^\s]{30,}/, "blahblah")
    clean_text = clean_text.gsub(/(blahblah ?){2,}/, "blahblah")

    message_parts = []
    message_parts << "*#{to} received email from #{from}*"
    message_parts << "_#{subject}_"
    message_parts << "<#{Rails.application.routes.url_helpers.email_url(id: id)}|Click here to view.>"
    message_parts << ">>> #{clean_text.truncate(2000)}"
    SlackNotifier.notify(message_parts.join("\n"), channel: "#portfolio", username: "Mail-Bot", icon_emoji: ":mailbox:")
  end
end
