class AddressBook
  include DistanceHelper, CoordCalculator

  # Cross-state happens. Cross-ocean does not. A bare venue name with no city
  # geocodes confidently to the other side of the world — "The Neurodiversity
  # Clinic" landing ~980mi away and producing a 16h drive — so anything this far
  # from where the person is is a wrong geocode, not a destination. Measured from
  # `current_loc` (the live coord, falling back to home) so a trip doesn't make
  # every venue around them implausible. Shared with AgendaTravelChain::Resolver,
  # which delegates here.
  MAX_DRIVE_MILES = 1_000
  FEET_PER_MILE   = 5_280.0

  def self.me
    new(User.me)
  end

  def initialize(user)
    @user = user
  end

  def contacts
    @contacts ||= @user.contacts
  end

  def addresses
    @addresses ||= @user.addresses
  end

  def home
    contact_by_name("Home")&.primary_address
  end

  def current_coord
    LocationCache.last_coord
  end

  def current_loc
    current_coord || home&.loc || []
  end

  def current_contact
    contact_by_loc(current_coord) || home&.contact
  end

  def current_address
    address_by_loc(current_coord) || home
  end

  def contact_by_loc(loc)
    find_contact_near(loc)
  end

  def address_by_loc(loc)
    find_address_near(loc)
  end

  def contact_by_name(name)
    contacts.name_find(name)
  end

  # Smart contact lookup that tries natural-language variants in priority
  # order: the original string first, then with possessive / location-suffix
  # / plural normalizations stripped. "Sarah", "Sarah's", "Sarah's house",
  # "Sarah's place", "Sarahs" all resolve to the same Sarah contact.
  # Returns the first matching Contact, or nil.
  def match_contact(name)
    self.class.name_variants(name)
      .lazy
      .map { |variant| contact_by_name(variant) }
      .find(&:present?)
  end

  # Strings the Distance Matrix API can't (and shouldn't) be billed for:
  # video-conf URLs, raw phone numbers, "tbd"/"online"/"virtual" placeholders.
  # Caller responsibility to early-out when this returns true — keeps the
  # API call (and the surrounding cache key) from being created with junk.
  NON_TRAVELABLE_PREFIX = %r{\A(https?://|www\.|tel:|phone:|mailto:)}i
  NON_TRAVELABLE_HOST = %r{\A(meet\.google\.com|zoom\.us|.*\.zoom\.us|teams\.microsoft\.com|webex\.com|.*\.webex\.com)}i
  NON_TRAVELABLE_PLACEHOLDER = /\A(tbd|tba|online|virtual|zoom|remote|n\/?a)\z/i
  NON_TRAVELABLE_PHONE = /\A[\d\s\-+().]+\z/

  def self.non_travelable?(str)
    s = str.to_s.strip
    return true if s.empty?
    return true if s.match?(NON_TRAVELABLE_PREFIX)
    return true if s.match?(NON_TRAVELABLE_HOST)
    return true if s.match?(NON_TRAVELABLE_PLACEHOLDER)
    return true if s.match?(NON_TRAVELABLE_PHONE) && s.length < 20

    false
  end

  # Normalize natural-language variants down to candidate contact names.
  # Public/class-level so callers without an AddressBook instance can ask
  # for the candidate list directly (e.g. for debugging).
  def self.name_variants(text)
    text = text.to_s.strip
    return [] if text.empty?

    variants = [text]
    # Strip possessive `'s`, optionally followed by "house"/"home"/"place":
    # "Sarah's", "Sarah's house", "Sarah's place(s)" all collapse to "Sarah".
    variants << text.sub(/['’]s(\s+(house|home|place)s?)?\b/i, "").strip
    # Apostrophe-less plural ("Sarahs" → "Sarah"). Gated by no-apostrophe so
    # we don't touch the already-handled possessive case. May generate a
    # noise variant for genuine names ending in `s` ("Charles" → "Charle"),
    # which simply misses the contact lookup harmlessly.
    variants << text.sub(/(\b[A-Z][a-z]+)s\b/, '\1') if text.exclude?("'") && text.exclude?("’")
    variants.uniq.compact_blank
  end

  def loc_from_address(address)
    geocode(address)
  end

  def to_address(data)
    data = BetterJsonSerializer.load(data)
    return data[:street] if data.is_a?(BetterJson)
    return data.street if data.is_a?(Address)
    return data.primary_address&.street if data.is_a?(Contact)

    address = data.first if data.is_a?(Array) && data.length == 1
    address = reverse_geocode(data, get: :address) if data.is_a?(Array) && data.length == 2
    data.tap { |str|
      next unless str.is_a?(String)
      next unless str.match?(/-?\d+(?:\.\d+)?, ?-?\d+(?:\.\d+)?/)

      coords = str.split(/, ?/).map(&:to_f)
      address = reverse_geocode(coords, get: :address)
    }
    return address if address.present?

    address = data[::Jarvis::Regex.address]&.squish.presence if data.is_a?(String) && data.match?(::Jarvis::Regex.address)
    address ||= contact_by_name(data)&.primary_address&.street
    address ||= nearest_from_name(data)
    address.gsub("\n", ", ").squish if address.is_a?(String)
    SlackNotifier.notify("to_address is a #{data.class}\n```#{data.inspect}```") unless data.is_a?(String)
    address
  end

  def traveltime_seconds(to, from=nil, at: nil)
    return 2700 unless Rails.env.production?

    from ||= current_loc
    to, from = [to, from].map { |input| to_traveltime_param(input) }
    return if to.blank? || from.blank?
    return 0 if to == from # same place — no API call needed

    # Google's Distance Matrix only returns traffic-aware estimates when called
    # with departure_time (driving mode ignores arrival_time). Use the event's
    # arrival timestamp as the predicted departure when it's in the future;
    # otherwise fall back to "now" for the 15-min pre-check.
    departure = at.present? && at.to_i > Time.current.to_i ? at.to_i : "now"
    bucket = Time.current.to_i / 10.minutes.to_i
    nonnil_cache("traveltime_seconds(#{to},#{from},#{departure},#{bucket})") {
      ::PrettyLogger.info("\b[AddressCache] Traveltime #{to},#{from},#{departure}")
      params = {
        destinations:   to,
        origins:        from,
        key:            ENV.fetch("PORTFOLIO_GMAPS_PAID_KEY", nil),
        departure_time: departure,
        traffic_model:  "best_guess",
      }.compact_blank.to_query
      url = "https://maps.googleapis.com/maps/api/distancematrix/json?#{params}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      element = json.dig(:rows, 0, :elements, 0)
      element&.dig(:duration_in_traffic, :value) || element&.dig(:duration, :value)
    }
  rescue StandardError => e
    SlackNotifier.err(e, "Traveltime failed: (to:\"#{to}\", from:\"#{from}\")", user: @user)
    nil
  end

  # Normalize input shapes for the Google Distance Matrix API while skipping
  # unnecessary lookups. Unlike #to_address, this:
  #   • converts [lat, lng] arrays straight to "lat,lng" strings (no
  #     reverse_geocode round-trip — Google accepts coords directly)
  #   • for string input, tries the contact-name lookup so callers can pass
  #     "Home", "Sarah", "Sarah's house" and get the right street address,
  #     but skips the address-pattern regex / nearest-from-name fallbacks
  #     that #to_address adds
  # Falls back to the full #to_address pipeline for non-string/non-coord
  # objects (Contact, Address, BetterJson, etc.).
  def to_traveltime_param(input)
    if input.is_a?(Array) && input.length == 2 && input.all? { |v| v.is_a?(Numeric) }
      return input.join(",")
    end

    if input.is_a?(String)
      str = input.strip
      return nil if str.empty?
      return nil if self.class.non_travelable?(str)

      contact_address = match_contact(str)&.primary_address&.street
      return contact_address if contact_address.present?

      # Anchor the name near the user before handing it to Distance Matrix, which
      # otherwise geocodes a bare venue name globally and lands on the wrong
      # continent. Coords are unambiguous to the API; :reject means we found only
      # an implausibly-distant point (a wrong geocode) and would rather report no
      # drive than a 16h one; nil means nothing resolved, so keep the old
      # behaviour and let the raw string through.
      point = plausible_travel_point(str)
      return point.join(",") if point.is_a?(Array)
      return nil if point == :reject

      return str
    end

    to_address(input)
  end

  # A point near the person to drive to, or a signal when there isn't one.
  # Tries the cheap cascade first (contact / own address / geocode), then a
  # Places lookup biased to where they are — the right tool for a bare venue
  # name. Mirrors AgendaTravelChain::Resolver#resolve_location.
  def plausible_travel_point(name)
    direct = coords_for_location(name)
    return direct if valid_loc?(direct) && plausible_drive?(direct)

    biased = nearest_from_name(name, extract: :loc)
    return biased if valid_loc?(biased) && plausible_drive?(biased)

    # We resolved a point, it was just too far to be a drive — a confident wrong
    # geocode. Drop it rather than let the raw name re-geocode globally.
    return :reject if valid_loc?(direct) || valid_loc?(biased)

    nil
  end

  # Within MAX_DRIVE_MILES of where the person is. No origin to measure against
  # means no opinion — an install with no location cache and no home gets the old
  # behaviour, not a blanket refusal.
  def plausible_drive?(latlng, from: current_loc)
    origin = Array(from).compact
    return true if origin.length < 2 || Array(latlng).compact.length < 2

    distance_between(origin, latlng) / FEET_PER_MILE <= MAX_DRIVE_MILES
  end

  def nearest_from_name(name, loc: nil, extract: :address)
    return unless Rails.env.production?
    raise "Unacceptable extraction: #{extract}" unless extract.in?([:address, :loc])

    loc ||= current_loc
    return if name.blank? || loc.compact.blank?

    Rails.cache.fetch("nearest_from_name(#{name},#{loc.join(",")})") {
      ::PrettyLogger.info("\b[AddressCache] Nearest name #{name},#{loc.join(",")}")
      params = {
        input:        name,
        inputtype:    :textquery,
        fields:       [:formatted_address, :geometry].join(","),
        locationbias: "point:#{loc.join(",")}",
        key:          ENV.fetch("PORTFOLIO_GMAPS_PAID_KEY", nil),
      }.to_query

      url = "https://maps.googleapis.com/maps/api/place/findplacefromtext/json?#{params}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      json[:candidates]
    }.then { |candidates|
      if candidates&.one?
        candidates.first
      else
        candidates.sort_by { |candidate|
          next if candidate&.dig(:geometry, :location).blank?

          distance(loc, candidate.dig(:geometry, :location).values)
        }.compact.first
      end
    }.then { |candidate|
      case extract
      when :address then candidate&.dig(:formatted_address)
      when :loc then candidate&.dig(:geometry, :location)&.slice(:lat, :lng)&.values
      end
    }
  # Degrade to nil on a Places failure, exactly as #geocode and
  # #traveltime_seconds do for their calls. Without this, a thrown
  # findplacefromtext request (quota/billing/429/5xx/timeout) propagates out
  # of the AgendaTravelChain worker's `ensure_resolved_all` and aborts the
  # whole day's run before `persist_event` — so every event needing a Places
  # lookup silently loses its return-home leg and chaining. A nil here is the
  # Resolver's "couldn't resolve" path, which falls back to the typed location.
  rescue StandardError => e
    ::SlackNotifier.err(e, "nearest_from_name failed: (#{name}): [#{e.class}]:#{e.message}", user: @user)
    nil
  end

  # What to call the spot at [lat,lng], most specific answer first:
  #
  #   1. the named place of an appointment around now that it's at
  #   2. the nearest saved contact
  #   3. the nearest business (`establishments: true` only)
  #   4. the city
  #
  # A business is only worth naming where they've stopped. While moving, the
  # nearest one is whatever the road happens to pass, and the lookup is paid
  # for on every position report.
  def place_name(loc, establishments: false)
    return unless valid_loc?(loc)

    loc = loc.map(&:to_f)
    name = agenda_place_near(loc)
    name ||= find_contact_near(loc)&.name.presence
    name ||= nearest_establishment(loc) if establishments
    name || reverse_geocode(loc, get: :city)
  end

  # An appointment's venue is geocoded to one point and parked at another, so
  # this is wider than `near?`'s ~110m. Three times it is still the same lot.
  AGENDA_PLACE_RADIUS = 0.003
  # Arriving early and leaving late are both normal; the coordinate check is
  # what keeps the window honest.
  AGENDA_PLACE_BEHIND = 4.hours
  AGENDA_PLACE_AHEAD = 2.hours
  # Each candidate can cost a geocode the first time its location is seen.
  AGENDA_PLACE_MAX = 8

  # The short form of an appointment's location, when that location is a NAME
  # ("Horsetail Falls", "Costco - Riverton") and they're standing at it. A bare
  # street address has no name to give, so it's left for the business lookup,
  # which can find what's at that address.
  def agenda_place_near(loc)
    agenda_places.select { |place| near?(place[:loc], loc, AGENDA_PLACE_RADIUS) }.min_by { |place|
      distance(place[:loc], loc)
    }&.dig(:name)
  end

  # Cached for a few minutes because the car's position is named on every
  # push, and the calendar does not move that fast.
  def agenda_places
    bucket = Time.current.to_i / 5.minutes.to_i
    Rails.cache.fetch("agenda_places(#{@user.id},#{bucket})", expires_in: 10.minutes) {
      window = (Time.current - AGENDA_PLACE_BEHIND)..(Time.current + AGENDA_PLACE_AHEAD)
      scope = AgendaItem.where(agenda_id: Agenda.where(user_id: @user.id).select(:id))
      scope = scope.where(start_at: window, cancelled_at: nil, all_day: false)
      scope = scope.where.not(location: [nil, ""])
      scope.order(:start_at).limit(AGENDA_PLACE_MAX).filter_map { |item|
        next if self.class.non_travelable?(item.location)
        next if ::Buddy::Place.street?(item.location.strip)

        there = coords_for_location(item.travel_nav_address.presence || item.location)
        { name: ::Buddy::Place.short(item.location), loc: there.map(&:to_f) } if valid_loc?(there)
      }
    }
  rescue StandardError => e
    # A calendar that won't read is one fallback lost, never the name.
    Rails.logger.warn("[AddressBook] agenda_places: #{e.class}: #{e.message}")
    []
  end

  # How far a business can be from where they stopped and still be where they
  # are. A big-box store's point is the middle of the building, and the car is
  # out in the lot.
  ESTABLISHMENT_RADIUS_METERS = 150
  # Answers about an area rather than a business.
  NOT_ESTABLISHMENT_TYPES = %w[locality political route neighborhood premise street_address].freeze

  def nearest_establishment(loc)
    return unless Rails.env.production?

    nonnil_cache("nearest_establishment(#{loc.map { |l| l.round(4) }.join(",")})") {
      ::PrettyLogger.info("\b[AddressCache] Nearest establishment #{loc.join(",")}")
      params = {
        location: loc.join(","),
        radius:   ESTABLISHMENT_RADIUS_METERS,
        key:      ENV.fetch("PORTFOLIO_GMAPS_PAID_KEY", nil),
      }.to_query

      url = "https://maps.googleapis.com/maps/api/place/nearbysearch/json?#{params}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      json[:results].to_a.reject { |place|
        place[:geometry].blank? || place[:types].to_a.intersect?(NOT_ESTABLISHMENT_TYPES)
      }.min_by { |place|
        distance(loc, place.dig(:geometry, :location).values_at(:lat, :lng))
      }&.dig(:name)
    }
  rescue StandardError => e
    ::SlackNotifier.err(e, "nearest_establishment failed: (#{loc}): [#{e.class}]:#{e.message}", user: @user)
    nil
  end

  # The nearest of their addresses within `near?` of [lat,lng]. Two saved
  # places can sit inside one radius - a neighbour two doors down - and the
  # first row the table returns is not the one they're at.
  def find_address_near(coord)
    return unless coord.compact.length == 2

    addresses.select { |details|
      next unless details.loc&.compact&.length == 2

      near?(details.loc, coord)
    }.min_by { |details| distance(details.loc, coord) }
  end

  # Find contact at [lat,lng]
  def find_contact_near(coord)
    find_address_near(coord)&.contact
  end

  def nonnil_cache(key, &block)
    Rails.cache.fetch(key) {
      block.call
    }.tap { |val|
      Rails.cache.delete(key) if val.blank?
    }
  end

  # [lat, lng] for whatever a person wrote in a location field, which is
  # routinely a saved place's NAME rather than an address - "the gym", "TMS",
  # "Serenity". Three passes, cheapest first, and only the last one costs
  # anything: a saved contact, one of their own addresses by street, then a
  # geocode (which `nonnil_cache`s, so the same location asked twice is one
  # call).
  #
  # Lives here rather than in Buddy::ToolContext because none of it was ever
  # about Buddy - SuiteOnArrival has to turn an appointment's location into a
  # point to compare a phone against. ToolContext delegates.
  def coords_for_location(location)
    return if location.blank?

    loc = match_contact(location)&.primary_address&.loc
    return loc if valid_loc?(loc)

    loc = @user.addresses.where("street ILIKE ?", location.to_s.strip).first&.loc
    return loc if valid_loc?(loc)

    geo = geocode(location)
    geo if valid_loc?(geo)
  end

  # A pair of real numbers. A row with a null lat, or a 0.0 left over from a
  # failed geocode, is not a place.
  def valid_loc?(loc)
    loc.is_a?(Array) && loc.compact.length == 2 && loc.all? { |v| v.to_f.nonzero? }
  end

  # Get [lat,lng] from address
  def geocode(address)
    return if address.blank?

    nonnil_cache("geocode(#{address})") {
      ::PrettyLogger.info("\b[AddressCache] Geocoding #{address}")
      encoded = CGI.escape(address)
      url = "https://maps.googleapis.com/maps/api/geocode/json?address=#{encoded}&key=#{ENV.fetch(
        "PORTFOLIO_GMAPS_PAID_KEY", nil
      )}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      json.dig(:results, 0, :geometry, :location)&.then { |loc_data|
        [loc_data[:lat], loc_data[:lng]]
      }
    }
  end

  # Get address from [lat,lng]
  def reverse_geocode(loc, get: :city)
    return "Herriman" unless Rails.env.production?
    return if loc.compact.blank?

    nonnil_cache("reverse_geocode(#{loc.map { |l| l.round(2) }.join(",")},#{get})") {
      ::PrettyLogger.info("\b[AddressCache] Reverse Geocoding #{loc.join(",")},#{get}")
      url = "https://maps.googleapis.com/maps/api/geocode/json?latlng=#{loc.join(",")}&key=#{ENV.fetch(
        "PORTFOLIO_GMAPS_PAID_KEY", nil
      )}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      case get
      when :city
        json.dig(:results, 0, :address_components)&.find { |comp|
          comp[:types] == ["locality", "political"]
        }&.dig(:short_name)
      when :address
        json.dig(:results, 0, :formatted_address)
      end
    }
  rescue StandardError => e
    ::SlackNotifier.err(e, "reverse_geocode failed: (#{loc}): [#{e.class}]:#{e.message}", user: @user)
    nil
  end
end
