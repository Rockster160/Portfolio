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
#  job_triage         :jsonb            not null
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
  json_attributes :inbound_mailboxes, :outbound_mailboxes, :job_triage

  enum :direction, {
    inbound:  0, # Email sent to a registered domain
    outbound: 1, # Email sent from a registered domain
  }

  scope :ordered, -> { order(timestamp: :desc) }
  scope :not_archived, -> { where(archived_at: nil) }
  scope :archived,     -> { where.not(archived_at: nil) }
  scope :unread,       -> { where(read_at: nil) }
  scope :read,         -> { where.not(read_at: nil) }

  # Inbound mail Emails::JobTriage has looked at. The "no" verdicts are kept
  # alongside the "yes" ones for two reasons: they are the record of what was
  # considered and turned down, which is the only way to tune the prompt
  # afterwards, and they are what stops a retry paying to reach the same answer
  # twice.
  scope :triaged,     -> { where.not(job_triage: {}) }
  scope :not_triaged, -> { where(job_triage: {}) }
  scope :job_mail,    -> { where("(emails.job_triage ->> 'job') = 'true'") }
  scope :in, ->(*mailboxes) {
    mailboxes = Array.wrap(mailboxes).flatten
    next mailboxes.inject(self) { |obj, method| obj.in(method) } unless Array.wrap(mailboxes).one?

    case mailboxes.first.to_sym
    when :inbox    then inbound.not_archived
    when :sent     then outbound
    when :read     then read
    when :unread   then unread
    when :archived then archived
    # when :failed   then failed
    when :all      then all
    else none
    end
  }
  # Us | Internal
  scope :with_inbound_name, ->(name) {
    where("inbound_mailboxes @> ?", [{ name: name }].to_json)
  }
  scope :with_inbound_address, ->(address) {
    where("inbound_mailboxes @> ?", [{ address: address }].to_json)
  }
  # Them | External
  scope :with_outbound_name, ->(name) {
    where("outbound_mailboxes @> ?", [{ name: name }].to_json)
  }
  scope :with_outbound_address, ->(address) {
    where("outbound_mailboxes @> ?", [{ address: address }].to_json)
  }

  def self.query(q)
    return inbound.not_archived if q.blank?

    res = super

    mailboxes = Tokenizing::Node.parse(q).flatten.filter_map { |node|
      node.is_a?(Hash) && node[:field] == "in" ? node[:conditions] : nil
    }.map(&:to_sym)
    res = res.inbound unless mailboxes.intersect?([:all, :sent])
    res = res.not_archived unless mailboxes.intersect?([:all, :archived])

    res
  end

  # TODO: SEND emails should also use S3

  def for_local # Call in prod to get code to call locally
    "::Email.parse(\"#{mail_blob.key}\")"
  end

  def self.parse(s3_object_key, bucket: "ardesian-emails")
    # 0fbk4c83djki6ol1v7d992kakp3ur7eq50sal501
    ::ReceiveEmailWorker.new.perform(bucket, s3_object_key)
  end

  def self.registered_domains
    ["ardesian.com", "rocconicholls.me", "rdjn.me"]
  end

  def serialize(opts={})
    super.merge(body: to_html, blob: mail, from: from, to: to, archived?: archived?)
  end

  💾(:mail) { ::Mail.new(mail_blob.download) }
  💾(:parser) { ::Emails::ParseMail.call(mail) }

  💾(:from) { inbound? ? outbound_mailboxes : inbound_mailboxes }
  💾(:to) { inbound? ? inbound_mailboxes : outbound_mailboxes }
  💾(:text_body) { parser.text_part }
  💾(:html_body) { parser.html_part }
  # The files the message came with, off the copy on S3. `has_attachments` is
  # the flag the list view paints a paperclip from; this is the thing itself,
  # and nothing but this can reach it - an attachment has no URL anywhere, it
  # only exists inside the mail.
  💾(:attachments) { parser.attachments.to_a }

  # One attachment by its position in that list. The POSITION is the handle
  # because a filename is neither unique within a message nor safe in a path -
  # two parts called `image001.png` is the ordinary shape of a signature.
  def attachment_at(index)
    return nil if index.to_i.negative?

    attachments[index.to_i]
  end

  def to_html
    html_body
  end

  # "Name <address>" for the two parties, direction-aware through the `from`/`to`
  # readers — a row of raw mailbox hashes is not something to show a person.
  def from_display = ::Emails::Normalizer.addresses_from_meta(from).join(", ")
  def to_display = ::Emails::Normalizer.addresses_from_meta(to).join(", ")

  # The form params that prefill a reply: the sender becomes the recipient, the
  # subject carries one `RE:`, and the From is the box this mail reached us at.
  def reply_defaults
    local, domain = reply_from.split("@", 2)
    {
      to:          from.filter_map { |mailbox| mailbox[:address] }.join(", "),
      subject:     "RE: #{::Emails::Normalizer.subject(subject)}",
      from_user:   local,
      from_domain: domain,
    }
  end

  # A forward keeps the body and leaves the recipient blank for the sender to
  # fill, so the original message travels on under an `FWD:`.
  def forward_defaults
    local, domain = reply_from.split("@", 2)
    {
      subject:     "FWD: #{::Emails::Normalizer.subject(subject)}",
      from_user:   local,
      from_domain: domain,
      html_body:   to_html,
    }
  end

  # The registered-domain address this message is ours on, so a reply leaves
  # from the same box. `inbound_mailboxes` is always our side regardless of
  # direction; mail that reached a personal Gmail falls back to the house
  # address, since a reply can only leave from a domain we control.
  def reply_from
    inbound_mailboxes.filter_map { |mailbox| mailbox[:address] }.find { |address|
      address.split("@", 2).last.in?(self.class.registered_domains)
    } || "contact@ardesian.com"
  end

  def show_mailboxes(type=:inbound)
    ::Emails::Normalizer.addresses_from_meta(send("#{type}_mailboxes")).then { |addresses|
      addresses.size == 1 ? addresses.first : "[#{addresses.join(" | ")}]"
    }
  end

  def triaged? = job_triage.present?
  def job_mail? = job_triage[:job] == true

  # The JobNote this email was turned into, if somebody took the offer. Nil is
  # the ordinary state - most job mail is read and needs nothing logged.
  def job_note = (::JobNote.find_by(id: job_triage[:job_note_id]) if job_triage[:job_note_id])

  def archive! = update!(archived_at: ::Time.current)
  def archived? = archived_at?
  def read! = update!(read_at: ::Time.current)
  def read? = read_at?
  def unread? = !read_at?

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
end
