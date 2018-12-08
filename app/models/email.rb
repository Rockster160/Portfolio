#== Schema Information
#
# Table name: emails
#
#  id         :integer          not null, primary key
#  sent_by_id :integer
#  from       :string
#  to         :string
#  subject    :string
#  blob       :text
#  text_body  :text
#  html_body  :text
#  read_at    :datetime
#  deleted_at :datetime
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

class Email < ApplicationRecord
  attr_accessor :skip_validations, :from_user, :from_domain
  belongs_to :sent_by, class_name: "User", optional: true

  scope :not_archived, -> { where(deleted_at: nil) }
  scope :from_us,     -> { where(registered_domains.map { |domain| "emails.from ILIKE '%#{domain}'" }.join(" OR ")) }
  scope :not_from_us, -> { where.not(registered_domains.map { |domain| "emails.from ILIKE '%#{domain}'" }.join(" OR ")) }
  scope :unread,      -> { where(read_at: nil) }
  scope :read,        -> { where.not(read_at: nil) }
  scope :failed,      -> { where.not(blob: nil).where(from: nil, to: nil) }

  scope :order_chrono, -> { order(created_at: :desc) }

  def self.receive(req)
    blob = req.try(:raw_post).to_s
    email = create(blob: blob, skip_validations: true)
    email.reload.parse_blob if email.persisted?
  end

  def self.from_mail(mail)
    new.from_mail(mail)
  end

  def self.domains_from_addresses(*addresses)
    addresses.map { |address| address.to_s.split("@").first.to_s.squish }.reject(&:blank?)
  end

  def notify_slack
    message_parts = []
    message_parts << "*#{to} received email from #{from}*"
    message_parts << "_#{subject}_"
    message_parts << "<#{Rails.application.routes.url_helpers.email_url(id: id)}|Click here to view.>"
    message_parts << ">>> #{text_body}"
    SlackNotifier.notify(message_parts.join("\n"), channel: '#portfolio', username: 'Mail-Bot', icon_emoji: ':mailbox:')
  end

  def from_us?
    (Email.domains_from_addresses(from) & Email.registered_domains).any?
  end

  def not_from_us?
    (Email.domains_from_addresses(to) & Email.registered_domains).any?
  end

  def not_our_email
    from_us? ? from : to
  end

  def our_email
    from_us? ? to : from
  end

  def from_user
    (from&.split("@", 2)&.first || @from_user&.split("@", 2)&.first).to_s.downcase
  end

  def from_domain
    (from&.split("@", 2)&.last || @from_domain&.split("@", 2)&.last).to_s.downcase
  end

  def self.registered_domains
    ["ardesian.com", "rocconicholls.me"]
  end

  def to_mail
    Mail.new(
      from:    from,
      to:      to&.split(","),
      subject: subject,
      body:    html_body
    )
  end

  def from_mail(mail)
    text_body = mail.try(:text_part).try(:body).try(:raw_source)
    text_body = text_body.gsub(/\=(3D)+/, "=").gsub(/\=\r?\n/, "") if text_body.present?
    html_body = mail.try(:html_part).try(:body).try(:raw_source) || mail.try(:body).try(:raw_source)
    html_body = html_body.gsub(/\=(3D)+/, "=").gsub(/\=\r?\n/, "").gsub(/\r?\n\r?/, "<br>") if html_body.present?
    assign_attributes(
      from:      [mail.from].flatten.compact.join(","),
      to:        [mail.to].flatten.compact.join(","),
      subject:   mail.subject,
      text_body: text_body,
      html_body: html_body
    )
    notify_slack if save
    failure(*errors.full_messages) if errors.any?
    reload
  end

  def failure(*issues)
    SlackNotifier.notify("Failed to parse: \n* #{issues.join("\n* ")}\n<#{Rails.application.routes.url_helpers.email_url(id: id)}|Click here to view.>", channel: '#portfolio', username: 'Mail-Bot', icon_emoji: ':mailbox:') if issues.any?
  end

  def deliver!
    ApplicationMailer.deliver_email(id).deliver_later
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
    self.text_body ||= Nokogiri::HTML.parse(html_body).xpath("//text()").map(&:text).join(" ") rescue nil
    errors.add(:text_body, "must exist") unless text_body.present?
  end

  def parse_blob
    return if text_body.present? || blob.blank?
    json = JSON.parse(blob) rescue nil
    message = JSON.parse(json&.dig("Message")) rescue nil
    return failure("No message") unless message&.is_a?(Hash)
    content = message["content"]
    mail = Mail.new(content)
    from_mail(mail)
  end
end
