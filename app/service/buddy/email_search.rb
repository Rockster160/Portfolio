module Buddy
  # One person's mail, searched with the same `query` the emails page runs, so
  # a search that works in that box works here too and the other way round.
  #
  # The page's blank search is the inbox, and any search stays inside it -
  # received and not archived - until a term reaches past it. Archiving is
  # filing, not forgetting: "did the vet email back?" is about mail that may
  # well have been archived the day it came, so this always reaches the
  # archive, and an archive term in the search narrows it like any other.
  # Received-only still holds until a direction or an address is named, the
  # same as the page.
  module EmailSearch
    module_function

    LIMIT   = 8
    MAX     = 20
    SNIPPET = 160

    FIELDS = %i[from to subject after before].freeze

    # The convenience fields become the query syntax rather than SQL of their
    # own, so they mean exactly what the same words typed into the box mean.
    def fields_query(**fields)
      FIELDS.filter_map { |key| "#{key}:#{quote(fields[key])}" if fields[key].present? }.join(" ")
    end

    # What was searched, as the person would type it into the emails page.
    def describe(query, fields)
      [query.to_s.strip.presence, fields_query(**fields).presence].compact.join(" ")
    end

    # The query and the fields run as two searches ANDed together, never as
    # one string. The parser binds a term written after `a OR b` to `b` alone,
    # parentheses or not, so `from:` appended to an OR chain narrowed only its
    # last alternative and every other one reached any sender.
    #
    # `in:all` is the page's own way of switching its inbox defaults off; with
    # them off, received-only is put back here unless the search names a
    # direction or an address, and the archive is left in.
    def call(user:, query: nil, limit: LIMIT, **fields)
      query  = query.to_s.strip
      narrow = fields_query(**fields)
      terms  = ::Email.query_terms(quoted(describe(query, fields)))
      sided  = ::Email.terms_reach?(terms, ::Email::DIRECTION_TERMS) || terms.keys.intersect?(::Email::ADDRESS_FIELDS)

      ::Email.reset_search_notes
      scope = user.emails.query("#{query} in:all".strip)
      scope = scope.query("#{narrow} in:all") if narrow.present?
      scope = scope.where(user_id: user.id)
      scope = scope.inbound unless sided
      {
        emails:   scope.ordered.limit(limit.to_i.clamp(1, MAX)).to_a,
        total:    scope.count,
        problems: ::Email.search_notes.dup.presence,
      }
    end

    def quoted(q)
      q.gsub(::Email::ADDRESS_TOKEN_RX) { "\"#{Regexp.last_match(1)}\"" }
    end

    def rows(emails, user)
      emails.map { |email| row(email, user) }
    end

    def row(email, user)
      {
        id:          email.id,
        from:        email.from_display.presence,
        to:          (email.to_display.presence if email.outbound?),
        subject:     email.subject.presence,
        at:          Buddy::EventSearch.when_phrase(email.timestamp, user),
        snippet:     email.blurb.to_s.squish.truncate(SNIPPET).presence,
        sent:        (true if email.outbound?),
        archived:    (true if email.archived?),
        attachments: (true if email.has_attachments?),
      }.compact
    end

    # One message in full. The body is read off S3, so a mail that can't be
    # fetched still gives back its headers and the snippet the row was stored
    # with, and says so rather than looking empty.
    def read(email, user)
      body = Buddy::JobMailOffer.mail_text(email)
      row(email, user).except(:snippet).merge(
        text:        body || email.blurb.to_s.squish.presence,
        partial:     (true if body.nil?),
        attachments: attachment_names(email),
        link:        ::Rails.application.routes.url_helpers.email_path(email),
      ).compact
    end

    def attachment_names(email)
      return nil unless email.has_attachments?

      email.attachments.map { |part| part.filename.presence || part.mime_type }.compact.presence
    rescue StandardError
      nil
    end

    def quote(value)
      value = value.to_s.strip
      value.match?(/[\s:()]/) ? "\"#{value.delete('"')}\"" : value
    end
  end
end
