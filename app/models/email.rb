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
#  tags               :text             default([]), not null, is an Array
#  timestamp          :datetime         not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  mail_id            :text             not null
#  user_id            :bigint           not null
#

class Email < ApplicationRecord
  include ::GroupTaggable, ::Memoizable

  # `from:`/`to:` are scopes rather than columns, and named `_search` because
  # `from` is ActiveRecord's own FROM-clause method - calling it with an address
  # built a query against a table called `rocco@rdjn.com`.
  search_terms(
    :id, :subject,
    from:        :from_search,
    to:          :to_search,
    address:     :address_search,
    in:          :in,
    is:          :is_search,
    has:         :has_search,
    tag:         :tag_search,
    before:      :before_search,
    after:       :after_search,
    timestamp:   :timestamp,
    read_at:     :read_at,
    archived_at: :archived_at
  )

  # Terms that reach outside the inbox, so a search naming one is not also held
  # to received, unarchived mail. See `query`.
  DIRECTION_TERMS = {
    in: [:sent, :all],
    is: [:sent, :outbound, :inbound, :received],
  }.freeze
  ARCHIVE_TERMS = {
    in: [:archived, :all],
    is: [:archived, :unarchived],
  }.freeze
  ADDRESS_FIELDS = [:from, :to, :address].freeze

  # An address or domain splits on `@` and `.` into operators, so
  # `to:rocco@rdjn.com` parsed as three nested fields and matched nothing.
  # Quoted, it is one value.
  ADDRESS_TOKEN_RX = /(?<=\A|[\s:(])(?!["'])([^\s"'():<>=!]*(?:@|\w\.\w)[^\s"'()<>=!]*)/

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

  # ---- query-syntax scopes (called by ApplicationRecord#query via search_terms) ----

  # Free text: subject, the snippet, either party's name or address, and tags.
  # The body lives on S3 and is not searchable.
  scope :search, ->(word) {
    like = "%#{sanitize_sql_like(word.to_s)}%"
    search_scope.where(
      "emails.subject ILIKE :like OR emails.blurb ILIKE :like " \
      "OR emails.inbound_mailboxes::text ILIKE :like " \
      "OR emails.outbound_mailboxes::text ILIKE :like " \
      "OR array_to_string(emails.tags, ' ') ILIKE :like",
      like: like,
    )
  }
  # Substring on the name or address, so `from:amazon.com` reaches
  # `orders@amazon.com` and `from:billy` reaches "Billy Bob".
  scope :mailbox_search, ->(column, value) {
    where(
      "EXISTS (SELECT 1 FROM jsonb_array_elements(emails.#{column}) mbx " \
      "WHERE mbx->>'address' ILIKE :like OR mbx->>'name' ILIKE :like)",
      like: "%#{sanitize_sql_like(value.to_s.strip)}%",
    )
  }
  # Direction-aware, the same way the `from`/`to` readers are: our side is
  # always `inbound_mailboxes`, so the sender is theirs on inbound mail and ours
  # on outbound.
  scope :from_search, ->(value) {
    inbound.mailbox_search(:outbound_mailboxes, value).or(
      outbound.mailbox_search(:inbound_mailboxes, value),
    )
  }
  scope :to_search, ->(value) {
    inbound.mailbox_search(:inbound_mailboxes, value).or(
      outbound.mailbox_search(:outbound_mailboxes, value),
    )
  }
  scope :address_search, ->(value) {
    mailbox_search(:inbound_mailboxes, value).or(mailbox_search(:outbound_mailboxes, value))
  }
  scope :is_search, ->(value) {
    case value.to_s.downcase.to_sym
    when :read                 then read
    when :unread               then unread
    when :archived             then archived
    when :unarchived, :inbox   then not_archived
    when :inbound, :received   then inbound
    when :outbound, :sent      then outbound
    when :job                  then job_mail
    when :tagged               then where.not(tags: [])
    when :untagged             then where(tags: [])
    else none
    end
  }
  scope :has_search, ->(value) {
    case value.to_s.downcase.to_sym
    when :attachment, :attachments then where(has_attachments: true)
    when :tag, :tags               then where.not(tags: [])
    else none
    end
  }
  scope :tag_search, ->(value) { tagged(value) }
  # `before:` is exclusive and `after:` inclusive, the way a mail client reads
  # them: `after:2026-10-01 before:2026-10-02` is the whole of the 1st.
  scope :before_search, ->(value) { date_search(:<, value) }
  scope :after_search, ->(value) { date_search(:>=, value) }
  scope :date_search, ->(operator, value) {
    begin
      where("emails.timestamp #{operator} ?", parse_date(value.to_s, operator: operator))
    rescue UnreadableDate => e
      where(note_search_problem("could not read the date #{e.message}"))
    end
  }

  # A blank search is the inbox. A search stays inside it - received and not
  # archived - unless it names something that reaches past it: a direction or
  # an address lifts the first, an archive state the second.
  #
  # Applied onto `all` rather than returned bare, because the base query
  # rebuilds from `unscoped` and would otherwise hand back every user's mail.
  def self.query(q)
    return all.inbound.not_archived if q.blank?

    q = q.to_s.gsub(ADDRESS_TOKEN_RX) { "\"#{Regexp.last_match(1)}\"" }
    terms = query_terms(q)
    res = merge(super)

    res = res.inbound unless terms_reach?(terms, DIRECTION_TERMS) || terms.keys.intersect?(ADDRESS_FIELDS)
    res = res.not_archived unless terms_reach?(terms, ARCHIVE_TERMS) || terms.key?(:archived_at)
    res
  end

  # { field => [values] } for every `field:value` in the search, however deep.
  # A bare address counts as `address:`, since it is matched on either side.
  def self.query_terms(q)
    ::Tokenizing::Node.parse(q).flatten.each_with_object({}) { |node, terms|
      # A bare word is a plain string beside other terms, and a field with no
      # operator when it stands alone.
      node = { field: node } if node.is_a?(::String)
      next unless node.is_a?(Hash) && node[:field].present?

      field, values = node[:field].to_sym, Array.wrap(node[:conditions]).grep(::String)
      field, values = :address, [node[:field]] if node[:operator].nil? && node[:field].include?("@")

      (terms[field] ||= []).concat(values.map { |val| val.downcase.to_sym })
    }
  end

  def self.terms_reach?(terms, reaching)
    reaching.any? { |field, values| terms.fetch(field, []).intersect?(values) }
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

  # Cast, because these arrive as form params and `"false"` is truthy.
  def archived=(value)
    boolean = ::ActiveModel::Type::Boolean.new.cast(value)
    if boolean && archived_at.nil?
      self.archived_at = ::Time.current
    elsif !boolean && archived_at.present?
      self.archived_at = nil
    end
  end

  def read=(value)
    boolean = ::ActiveModel::Type::Boolean.new.cast(value)
    if boolean && read_at.nil?
      self.read_at = ::Time.current
    elsif !boolean && read_at.present?
      self.read_at = nil
    end
  end

  # The comma-separated form of `tags`, for a text field.
  def tag_list = tags.join(", ")

  def tag_list=(value)
    self.tags = ::GroupTaggable.normalize(value)
  end
end
