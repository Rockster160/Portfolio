module Emails
  # The compose side of the mailbox: the few fields the form collects, the
  # checks that keep a half-addressed draft from leaving, and the one call that
  # sends it and files the copy.
  #
  # Deliberately NOT the Email model. An Email is a message that already exists —
  # its body and recipients are read back off the RFC822 blob on S3, so it has
  # no writable `to` or `html_body` to bind a form to. This holds the draft until
  # it becomes one of those: `deliver!` builds the mail, sends it through the
  # configured SMTP, and hands the raw bytes to StoreRaw, which writes the
  # outbound row the same way an inbound one is written.
  class Compose
    # Attributes first so its initialize sets up the typed attributes before
    # Model's assignment runs — the reverse order leaves them uninitialized.
    include ::ActiveModel::Attributes, ::ActiveModel::Model

    # Local part and domain are collected separately because the domain is a
    # pick from the registered set, never free text — mail can only leave from a
    # domain we actually control.
    attribute :from_user, :string
    attribute :from_domain, :string
    # A comma-separated list the way the recipient chips serialize it.
    attribute :to, :string
    attribute :subject, :string
    attribute :html_body, :string

    # The account the sent copy is filed under, and the uploaded files to attach.
    # Neither is a persisted attribute, so they sit outside ActiveModel::Attributes.
    attr_accessor :user, :tempfiles

    validates :from_user, presence: { message: "needs a name before the @" }
    validate :from_domain_registered
    validate :recipients_present

    def from_address
      "#{from_user.to_s.squish}@#{from_domain.to_s.squish}"
    end

    # The valid addresses out of the CSV, deduped. Invalid fragments are dropped
    # rather than rejected — a trailing comma or a stray word shouldn't cost the
    # whole send — and `recipients_present` is what fails an empty result.
    def recipient_addresses
      to.to_s.split(",").filter_map { |fragment| ::Emails::Normalizer.email(fragment) }.uniq
    end

    def attachment_files
      ::Array.wrap(tempfiles).compact_blank
    end

    # Sends, then files the copy. Order matters: a send that raises (SMTP is set
    # to raise in production) stops before a misleading "sent" row is written,
    # and a filing that fails never un-sends the mail — the row is the paperwork,
    # the delivery is the thing. Returns the sent message on success, nil when
    # the draft was rejected before anything left.
    def deliver!
      return nil if invalid?

      message = ::ApplicationMailer.compose(
        from:        from_address,
        to:          recipient_addresses,
        subject:     subject.to_s,
        html_body:   html_body.to_s,
        attachments: attachment_files,
      ).deliver_now

      ::Emails::StoreRaw.call(user: user, raw: message.to_s, direction: :outbound)
      message
    end

    private

    def from_domain_registered
      return if from_domain.to_s.squish.in?(::Email.registered_domains)

      errors.add(:from_domain, "must be a registered domain")
    end

    def recipients_present
      return if recipient_addresses.any?

      errors.add(:to, "needs at least one valid email address")
    end
  end
end
