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
#  user_id            :bigint           not null
#

class Email < ApplicationRecord
  include ::Memoizable
  search_terms :id, :from, :to, :in, :subject, timestamp: :created_at

  belongs_to :user

  has_one_attached :mail_blob, service: :s3_emails, dependent: :destroy

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

  # TODO: SEND emails should also use S3

  def self.registered_domains
    ["ardesian.com", "rocconicholls.me", "rdjn.me"]
  end

  💾(:mail) { ::Mail.new(mail_blob.download) }

  def to_html
    # TODO: This will not render attachments.
    raw = mail.html_part&.body&.decoded.presence || mail.body.decoded
    raw ||= "<pre>#{ERB::Util.html_escape(mail.text_part&.body&.decoded || mail.body.decoded)}</pre>"

    doc = ::Nokogiri::HTML.fragment(raw)
    doc.xpath("//script|//style").remove
    doc.to_html
  end

  def archive! = update!(archived_at: ::Time.current)
  def archived? = archived_at?
  def read! = update!(read_at: ::Time.current)
  def read?; read_at?; end
  def unread?; !read_at?; end

  # # def deliver!
  # #   ApplicationMailer.deliver_email(id, tempfiles).deliver_now
  # # end
end
