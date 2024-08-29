# == Schema Information
#
# Table name: emails
#
#  id          :integer          not null, primary key
#  attachments :text
#  blob        :text
#  deleted_at  :datetime
#  from        :string
#  html_body   :text
#  read_at     :datetime
#  subject     :string
#  text_body   :text
#  to          :string
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  sent_by_id  :integer
#  user_id     :bigint
#

class Email < ApplicationRecord
  attr_accessor :skip_validations, :from_user, :from_domain, :skip_notify, :tempfiles
  belongs_to :sent_by, class_name: "User", optional: true
  belongs_to :user, optional: true

  serialize :attachments, coder: JsonWrapper

  scope :not_archived, -> { where(deleted_at: nil) }
  scope :archived,     -> { where.not(deleted_at: nil) }
  scope :outbound,     -> { where(registered_domains.map { |domain| "emails.from ILIKE '%#{domain}'" }.join(" OR ")) }
  scope :inbound,      -> { where.not(registered_domains.map { |domain| "emails.from ILIKE '%#{domain}'" }.join(" OR ")) }
  scope :unread,       -> { where(read_at: nil) }
  scope :read,         -> { where.not(read_at: nil) }
  scope :failed,       -> { where.not(blob: nil).where(from: nil, to: nil) }
  scope :search,       ->(str) {
    str = "%#{str}%"
    where("
      emails.from ILIKE :str OR
      emails.to ILIKE :str OR
      emails.subject ILIKE :str OR
      emails.text_body ILIKE :str
    ", str: str)
    # Maybe also search attachment names?
  }

  scope :order_chrono, -> { order(created_at: :desc) }

  def self.from_mail(mail, attaches=[])
    new.from_mail(mail, attaches)
  end

  def self.domains_from_addresses(*addresses)
    addresses.map { |address| address.to_s.split("@", 2).last.to_s.squish }.reject(&:blank?)
  end

  def self.registered_domains
    ["ardesian.com", "rocconicholls.me", "rdjn.me"]
  end

  def notify_slack
    clean_text = text_body.to_s.gsub(/\n{3,}/, "\n\n")
    clean_text = clean_text.gsub(/\b= \b/, "")
    clean_text = clean_text.gsub(/[^\s]{30,}/, "blahblah")
    clean_text = clean_text.gsub(/(blahblah blahblah ?)+/, "blahblah")

    message_parts = []
    message_parts << "*#{to} received email from #{from}*"
    message_parts << "_#{subject}_"
    message_parts << "<#{Rails.application.routes.url_helpers.email_url(id: id)}|Click here to view.>"
    message_parts << ">>> #{clean_text.truncate(2000)}"
    SlackNotifier.notify(message_parts.join("\n"), channel: "#portfolio", username: "Mail-Bot", icon_emoji: ":mailbox:")
  end

  def retrieve_attachments
    @retrieve_attachments ||= begin
      (attachments || []).each_with_object({}) do |(attch_id, attch_filename), obj|
        obj[attch_id] = {
          filename: attch_filename,
          presigned_url: FileStorage.expiring_url(attch_filename)
        }
      end.with_indifferent_access
    end
  end

  def outbound?
    (::Email.domains_from_addresses(to) & ::Email.registered_domains).any?
  end

  def inbound?
    (::Email.domains_from_addresses(from) & ::Email.registered_domains).any?
  end

  def inbound_address
    outbound? ? to : from
  end

  def outbound_address
    outbound? ? from : to
  end

  def from_user
    (from&.split("@", 2)&.first || @from_user&.split("@", 2)&.first).to_s.downcase
  end

  def from_domain
    (from&.split("@", 2)&.last || @from_domain&.split("@", 2)&.last).to_s.downcase
  end

  def html_for_display
    with_attach = html_body.gsub(/src\=\"cid\:(\w+)\"/) do |found|
      cid = Regexp.last_match(1)
      "src=\"#{retrieve_attachments&.dig(cid, :presigned_url)}\""
    end
    open_links_in_new_tab = with_attach.gsub(/\<a\s/, "<a target=\"_blank\" ")

    open_links_in_new_tab
  end

  def to_mail
    Mail.new(
      from:    from,
      to:      to&.split(","),
      subject: subject,
      body:    html_body
    )
  end

  def clean_content(raw_html, parse_text: false)
    return unless raw_html.present?

    html = raw_html.encode("UTF-8", invalid: :replace, undef: :replace, replace: "", universal_newline: true).gsub(/\P{ASCII}/, "")
    return html unless parse_text

    parser = Nokogiri::HTML(html, nil, Encoding::UTF_8.to_s)
    parser.xpath("//script")&.remove
    parser.xpath("//style")&.remove
    parser.xpath("//text()").map(&:text).join(" ").squish
  end

  def amazon_update?(from)
    ([
      "auto-confirm@amazon.com",
      "order-update@amazon.com",
      "shipment-tracking@amazon.com",
    ] & from).any?
  end

  def parse_amazon
    AmazonEmailParser.parse(self)
  end

  def matching_user_id
    addresses = self.to.split(",")
    addresses.find { |address|
      personal, domain = address.split("@", 2)
      next unless domain.in?(::Email.registered_domains)

      user_id = User.ilike(username: personal.split("+").first).take&.id
      break user_id if user_id.present?
    }
  end

  def serialize
    # Shouldn't return blob, just need to figure out how to parse email data better so we have access to nickname and properly parsed html data
    as_json(only: [:id, :from, :to, :subject, :text_body, :html_body, :blob, :created_at])
  end

  def from_mail(mail, attaches=[])
    content = mail.body&.decoded.presence
    html_body = clean_content(mail.html_part&.body&.decoded.presence) || clean_content(content)
    text_body = clean_content(mail.text_part&.body&.decoded.presence) || clean_content(content, parse_text: true)

    self.to = [mail.to].flatten.compact.join(",")
    user_id = matching_user_id || User.me.id
    assign_attributes(
      from:      [mail.from].flatten.compact.join(","),
      subject:   mail.subject,
      text_body: text_body,
      html_body: html_body,
      attachments: attaches,
      user_id: user_id,
    )
    self.blob = self.blob.presence || mail.to_s

    success = save

    ::Jarvis.trigger_events(user_id, :email, serialize)
    ::Jil::Executor.async_trigger(user_id, :email, serialize)
    # Async is fine here because the code below should be in a task, not hard coded.
    # The save above should be save! with a rescue that updates the status to failed parse and alerts Slack (as a dev/code error, not Jil error)

    # TODO: Remove the below- these should be taken care of via tasks, including the Slack notifier

    blacklist = [
      "LV Bag",
      "Louis Vuitton"
    ]

    if amazon_update?([mail.from].flatten.compact)
      parse_amazon
      archive # Auto archive Amazon emails
    elsif blacklist.any? { |bad| html_body.include?(bad) }
      archive
    end

    reload
    notify_slack if success && !archived?
    failure(*errors.full_messages) if errors.any?
  end

  def failure(*issues)
    return if skip_notify
    SlackNotifier.notify("Failed to parse: \n* #{issues.join("\n* ")}\n<#{Rails.application.routes.url_helpers.email_url(id: id)}|Click here to view.>", channel: '#portfolio', username: 'Mail-Bot', icon_emoji: ':mailbox:') if issues.any?
  end

  def deliver!
    ApplicationMailer.deliver_email(id, tempfiles).deliver_now
  end

  def archive
    update(deleted_at: Time.current)
  end

  def read?; read_at?; end
  def unread?; !read_at?; end
  def archived?; deleted_at?; end

  def read=(val)
    self.read_at = Time.current if val
  end
  def archived=(val)
    self.deleted_at = val == "true" ? Time.current : nil
  end

  def read
    update(read_at: Time.current)
  end

  def set_send_values
    self.from ||= "#{@from_user.try(:squish)}@#{@from_domain.try(:squish)}"
    return errors.add(:from, "must be a registered domain.") unless from.split("@", 2)&.last.in?(self.class.registered_domains)
    email_regexp = /\A[^@\s]+@[^@\s]+\z/
    return errors.add(:from, "must be a valid email address.") unless from =~ email_regexp
    self.to = [to].flatten.compact.select { |to_address| to_address =~ email_regexp }.join(",")
    return errors.add(:to, "must be a valid email address.") unless to.present?
    # self.text_body ||= Nokogiri::HTML.parse(html_body).xpath("//text()").map(&:text).join(" ") rescue nil
    # errors.add(:text_body, "must exist") unless text_body.present?
  end

  def reparse!
    return if blob.blank?
    update(text_body: nil, html_body: nil, skip_notify: true)
    parse_blob
  end

  def parse_blob
    return if text_body.present?
    return if blob.blank?
    json = JSON.parse(blob) rescue nil
    message = JSON.parse(json&.dig("Message")) rescue nil
    return failure("No message") unless message&.is_a?(Hash)
    content = message["content"]
    mail = Mail.new(content)
    from_mail(mail)
  end
end
