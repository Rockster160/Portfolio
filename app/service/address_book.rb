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
    current_coord || home&.loc
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
    name = name.to_s.downcase
    return unless name.present?
    # Exact match (no casing)
    found = contacts.find_by("name ILIKE ?", name)
    found ||= contacts.find_by("nickname ILIKE ?", name)
    # Exact match without 's and/or house|place
    found ||= contacts.find_by("name ILIKE :name", name: name.gsub(/\'?s? ?(house|place)?$/, ""))
    found ||= contacts.find_by("nickname ILIKE :name", name: name.gsub(/\'?s? ?(house|place)?$/, ""))
    # Match without special chars
    found ||= contacts.find_by("REGEXP_REPLACE(name, '[^ a-z0-9]', '', 'i') ILIKE :name", name: name.gsub(/[^ a-z0-9]/, ""))
    found ||= contacts.find_by("REGEXP_REPLACE(nickname, '[^ a-z0-9]', '', 'i') ILIKE :name", name: name.gsub(/[^ a-z0-9]/, ""))
    # Match with only letters
    found ||= contacts.find_by("REGEXP_REPLACE(name, '[^a-z]', '', 'i') ILIKE :name", name: name.gsub(/[^a-z]/, ""))
    found ||= contacts.find_by("REGEXP_REPLACE(nickname, '[^a-z]', '', 'i') ILIKE :name", name: name.gsub(/[^a-z]/, ""))
  end

  def loc_from_address(address)
    geocode(address)
  end

  def to_address(data)
    data = BetterJsonSerializer.load(data)
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

    if data.is_a?(String) && data.match?(::Jarvis::Regex.address)
      address = data[::Jarvis::Regex.address]&.squish.presence
    end
    address ||= contact_by_name(data)&.primary_address&.street
    address ||= nearest_from_name(data)
    address.gsub("\n", "") if address.is_a?(String)
    SlackNotifier.notify("to_address is a #{data.class}\n```#{data.inspect}```") unless data.is_a?(String)
    address
  end

  def traveltime_seconds(to, from=nil, at: nil)
    return 2700 unless Rails.env.production?

    from ||= current_address
    # Should be stringified addresses
    to, from = [to, from].map { |address| to_address(address) }
    return if to.blank? || from.blank?

    nonnil_cache("traveltime_seconds(#{[to, from, at].compact_blank.join(",")})") {
      ::PrettyLogger.info("\b[AddressCache] Traveltime #{to},#{from},#{at}")
      params = {
        destinations: to,
        origins: from,
        key: ENV["PORTFOLIO_GMAPS_PAID_KEY"],
        arrival_time: at.presence&.to_i,
      }.compact_blank.to_query
      url = "https://maps.googleapis.com/maps/api/distancematrix/json?#{params}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      json.dig(:rows, 0, :elements, 0, :duration, :value)
    }
  rescue StandardError => e
    SlackNotifier.err(e, "Traveltime failed: (to:\"#{to}\", from:\"#{from}\")")
    nil
  end

  def nearest_from_name(name, loc: nil, extract: :address)
    raise "Unacceptable extraction: #{extract}" unless extract.in?([:address, :loc])

    loc ||= current_loc
    return if name.blank? || loc.compact.blank?

    nonnil_cache("nearest_from_name(#{name},#{loc.join(",")})") {
      ::PrettyLogger.info("\b[AddressCache] Nearest name #{name},#{loc.join(",")}")
      params = {
        input: name,
        inputtype: :textquery,
        fields: [:formatted_address, :geometry].join(","),
        locationbias: "point:#{loc.join(",")}",
        key: ENV["PORTFOLIO_GMAPS_PAID_KEY"],
      }.to_query

      url = "https://maps.googleapis.com/maps/api/place/findplacefromtext/json?#{params}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      json.dig(:candidates)
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

    nonnil_cache("geocode(#{address})") do
      ::PrettyLogger.info("\b[AddressCache] Geocoding #{address}")
      encoded = CGI.escape(address)
      url = "https://maps.googleapis.com/maps/api/geocode/json?address=#{encoded}&key=#{ENV["PORTFOLIO_GMAPS_PAID_KEY"]}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      json.dig(:results, 0, :geometry, :location)&.then { |loc_data|
        [loc_data[:lat], loc_data[:lng]]
      }
    end
  end

  # Get address from [lat,lng]
  def reverse_geocode(loc, get: :city)
    return "Herriman" unless Rails.env.production?
    return if loc.compact.blank?

    nonnil_cache("reverse_geocode(#{loc.map { |l| l.round(2) }.join(",")},#{get})") do
      ::PrettyLogger.info("\b[AddressCache] Reverse Geocoding #{loc.join(",")},#{get}")
      url = "https://maps.googleapis.com/maps/api/geocode/json?latlng=#{loc.join(",")}&key=#{ENV["PORTFOLIO_GMAPS_PAID_KEY"]}"
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
    end
  rescue StandardError => e
    ::SlackNotifier.err(e, "reverse_geocode failed: (#{loc}): [#{e.class}]:#{e.message}")
    nil
  end
end
