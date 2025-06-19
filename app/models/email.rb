# == Schema Information
#
# Table name: emails
#
#  id                 :bigint           not null, primary key
#  archived_at        :datetime
#  blurb              :text             not null
#  direction          :integer          not null
#  has_attachments    :boolean          default(FALSE), not null
#  inbound_mailboxes  :jsonb            not null
#  outbound_mailboxes :jsonb            not null
#  read_at            :datetime
#  subject            :text             not null
#  timestamp          :datetime         not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  mail_id            :text             not null
#  user_id            :bigint           not null
#

class Email < ApplicationRecord
  include ::Memoizable
  search_terms :id, :from, :to, :in, :subject, timestamp: :created_at

  belongs_to :user

  has_one_attached :mail_blob, service: :s3_emails, dependent: :destroy
  json_attributes :inbound_mailboxes, :outbound_mailboxes

  enum direction: {
    inbound: 0, # Email sent to a registered domain
    outbound: 1, # Email sent from a registered domain
  }

  scope :ordered, -> { order(timestamp: :desc) }
  scope :not_archived, -> { where(archived_at: nil) }
  scope :archived,     -> { where.not(archived_at: nil) }
  scope :unread,       -> { where(read_at: nil) }
  scope :read,         -> { where.not(read_at: nil) }
  scope :in, ->(*mailboxes) {
    mailboxes = Array.wrap(mailboxes).flatten
    next mailboxes.inject(self) { |obj, method| obj.in(method) } unless Array.wrap(mailboxes).one?
    case mailboxes.first.to_sym
    when :inbox    then inbound.not_archived
    when :sent     then outbound
    when :read     then read
    when :unread   then unread
    when :archived then archived
    when :failed   then failed
    when :all      then all
    else none
    end
  }
  # Us
  scope :with_inbound_name, ->(name) {
    where(
      "EXISTS (
        SELECT 1
        FROM   jsonb_array_elements_text(inbound_mailboxes) AS m(addr)
        WHERE  addr ILIKE ?
      )", "#{name} <%"
    )
  }
  # External
  scope :with_outbound_name, ->(name) {
    where(
      "EXISTS (
        SELECT 1
        FROM   jsonb_array_elements_text(outbound_mailboxes) AS m(addr)
        WHERE  addr ILIKE ?
      )", "#{name} <%"
    )
  }

  # TODO: SEND emails should also use S3

  def self.parse(s3_object_key, bucket: "ardesian-emails")
    # 0fbk4c83djki6ol1v7d992kakp3ur7eq50sal501
    ::ReceiveEmailWorker.new.perform(bucket, s3_object_key)
  end

  def self.registered_domains
    ["ardesian.com", "rocconicholls.me", "rdjn.me"]
  end

  def serialize(opts={})
    super(opts).merge(body: to_html, blob: mail, from: from, to: to)
  end

  💾(:mail) { ::Mail.new(mail_blob.download) }
  💾(:parser) { ::Emails::ParseMail.call(mail) }

  💾(:from) { inbound? ? outbound_mailboxes : inbound_mailboxes }
  💾(:to) { inbound? ? inbound_mailboxes : outbound_mailboxes }
  💾(:text_body) { parser.text_part }
  💾(:html_body) { parser.html_part }

  def to_html
    html_body
  end

  def archive! = update!(archived_at: ::Time.current)
  def archived? = archived_at?
  def read! = update!(read_at: ::Time.current)
  def read?; read_at?; end
  def unread?; !read_at?; end

  def archive(boolean)
    boolean ? archive! : update!(archived_at: nil)
  end
  def archived=(boolean)
    if boolean && archived_at.nil?
      self.archived_at = ::Time.current
    elsif !boolean && archived_at.present?
      self.archived_at = nil
    end
  end

  # # def deliver!
  # #   ApplicationMailer.deliver_email(id, tempfiles).deliver_now
  # # end
end
