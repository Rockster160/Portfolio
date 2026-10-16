# Puts the office address on an onsite interview's calendar row.
#
# A booking rarely carries its own address. Neighbor's arrived as two mails
# eight seconds apart - the calendar invite, filed as the `scheduled` note, and
# "Office Address: ..." as a plain note behind it - so the notes AROUND the
# booking are read, not only the booking. Run whenever any note on the
# application lands, so the second mail fills the row the first one made.
#
# Only ever fills a blank location. Whatever is already there was typed by a
# person or put there deliberately, and is never second-guessed.
#
# ByteInterviewPrep::HeadsUp reads the address too: a row with one gets no
# join link, because a link is no use to somebody already in the lobby.
module InterviewVenue
  module_function

  # How far either side of the booking a note can be and still be about it.
  NEAR = 3.days

  # An ATS receipt and the application itself quote the POSTING, and a posting
  # saying "on-site" is about the job, not the interview.
  IGNORED_TAGS = ["applied", "acknowledged"].freeze

  ONSITE_RE = /\b(?:on-?site|in[- ]person|office address|where to go|at our office)\b/i
  VIRTUAL_RE = /\b(?:virtual|remote|video)\s+on-?site\b/i

  SUFFIXES = [
    "St",
    "Street",
    "Ave",
    "Avenue",
    "Blvd",
    "Boulevard",
    "Pkwy",
    "Parkway",
    "Rd",
    "Road",
    "Dr",
    "Drive",
    "Ln",
    "Lane",
    "Way",
    "Ct",
    "Court",
    "Pl",
    "Place",
    "Plaza",
    "Hwy",
    "Highway",
    "Cir",
    "Circle",
    "Ter",
    "Terrace",
    "Trl",
    "Trail",
    "Loop",
    "Sq",
    "Square",
    "Pike",
    "Ctr",
    "Center",
  ].freeze

  # "2600 W Executive Pkwy, Suite 550, Lehi, UT 84043", and the grid form Utah
  # is full of - "1234 S 500 E" - which has no suffix at all.
  ADDRESS_RE = /
    \b\d{1,6}\s+
    (?:
      [NSEW]\.?\s+\d{1,5}\s+[NSEW]\b\.?
      |
      (?:[A-Za-z0-9.'-]+\s+){0,5}?(?:#{SUFFIXES.join("|")})\b\.?
    )
    (?:,?\s+(?:Suite|Ste\.?|Unit|Floor|Fl\.?|\#)\s*[\w-]+)?
    (?:,\s*[A-Za-z][A-Za-z .'-]*,\s*[A-Z]{2}(?:\s+\d{5}(?:-\d{4})?)?)?
  /x

  def place!(application)
    return if application.nil?

    upcoming = application.notes.where(tag: :scheduled, follow_up_at: Time.current..)
    upcoming.find_each { |booking| place_booking!(booking) }
  end

  def place_booking!(booking)
    item = booking.follow_up_item
    return if item.nil? || item.location.present?

    address = address_for(booking)
    return if address.nil?

    item.update(location: address)
    item.agenda.broadcast!
  end

  # The address, when the booking is onsite and one was written down. The
  # booking's own words first, then the nearest notes to it.
  def address_for(booking)
    texts = nearby(booking).map { |note| note.body.to_s }
    return nil unless texts.any? { |text| onsite?(text) }

    texts.lazy.filter_map { |text| address_in(text) }.first
  end

  def nearby(booking)
    scope = booking.job_application.notes.where.not(tag: IGNORED_TAGS)
    scope = scope.where(occurred_at: (booking.occurred_at - NEAR)..(booking.occurred_at + NEAR))
    others = scope.where.not(id: booking.id).to_a
    [booking, *others.sort_by { |note| (note.occurred_at - booking.occurred_at).abs }]
  end

  def onsite?(text)
    text.gsub(VIRTUAL_RE, "").match?(ONSITE_RE)
  end

  def address_in(text)
    text.gsub(/\s+/, " ")[ADDRESS_RE]&.sub(/[.,]+\z/, "")
  end
end
