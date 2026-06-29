class AddressBook
  include DistanceHelper

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
    SlackNotifier.err(e, "Traveltime failed: (to:\"#{to}\", from:\"#{from}\")")
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

      return str
    end

    to_address(input)
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
  end

  # Find address at [lat,lng]
  def find_address_near(coord)
    return unless coord.compact.length == 2

    addresses.find { |details|
      next unless details.loc&.compact&.length == 2

      near?(details.loc, coord)
    }
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
    ::SlackNotifier.err(e, "reverse_geocode failed: (#{loc}): [#{e.class}]:#{e.message}")
    nil
  end
end
