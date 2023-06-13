class AddressBook
  def initialize(user)
    @user = user
  end

  def contacts
    @contacts ||= @user.contacts
  end

  def home
    contact_by_name("Home")
  end

  def current_loc
    @user.jarvis_cache&.data&.dig(:car_data, :drive_state)&.then { |state|
      [state[:latitude], state[:longitude]]
    } || home&.loc
  end

  def current_contact
    @user.jarvis_cache&.data&.dig(:car_data, :drive_state)&.then { |state|
      contact_by_loc([state[:latitude], state[:longitude]])
    } || home
  end

  def current_address
    @user.jarvis_cache&.data&.dig(:car_data, :drive_state)&.then { |state|
      reverse_geocode([state[:latitude], state[:longitude]], get: :address)
    } || home&.address
  end

  def distance(c1, c2)
    # √[(x₂ - x₁)² + (y₂ - y₁)²]
    Math.sqrt((c2[0] - c1[0])**2 + (c2[1] - c1[1])**2)
  end

  def contact_by_loc(loc)
    near(loc)
  end

  def contact_by_name(name)
    name = name.to_s.downcase
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

  def loc_from_name
    # TODO - Give an address and find the lat/lng for it.
    # Should also have a UI where we can move the pin to a precise location.
    # Contacts should also have a preferred phone/address - perhaps just a bool on the associations?
  end

  def to_address(data)
    data = SafeJsonSerializer.load(data)
    address = data.first if data.is_a?(Array) && data.length == 1
    address = reverse_geocode(data, get: :address) if data.is_a?(Array) && data.length == 2
    data.tap { |str|
      next unless str.is_a?(String)
      next unless str.match?(/-?\d+(?:\.\d+)?, ?-?\d+(?:\.\d+)?/)

      coords = str.split(/, ?/).map(&:to_f)
      address = reverse_geocode(coords, get: :address)
    }
    return address if address.present?

    address ||= data[::Jarvis::Regex.address]&.squish.presence if data.match?(::Jarvis::Regex.address)
    address ||= contact_by_name(data)&.address
    address ||= nearest_address_from_name(data)
  end

  def traveltime_seconds(to, from=nil)
    return 2700 unless Rails.env.production?

    from ||= current_loc
    Rails.cache.fetch("traveltime_seconds(#{to},#{from})") do
      ::Jarvis.say("Traveltime #{to},#{from}")
      to, from = [to, from].map { |address| to_address(address) }
      # Should be stringified addresses

      params = {
        destinations: to,
        origins: from,
        key: ENV["PORTFOLIO_GMAPS_PAID_KEY"],
      }.to_query
      url = "https://maps.googleapis.com/maps/api/distancematrix/json?#{params}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      json.dig(:rows, 0, :elements, 0, :duration, :value)
    end
  rescue StandardError => e
    SlackNotifier.err(e, "Traveltime failed: (to:\"#{to}\", from:\"#{from}\")")
    nil
  end

  def nearest_address_from_name(name, loc=nil)
    loc ||= current_loc
    Rails.cache.fetch("nearest_address_from_name(#{name},#{loc.join(",")})") do
      ::Jarvis.say("Nearest name #{name},#{loc.join(",")}")
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

      if json&.dig(:candidates)&.one?
        json.dig(:candidates).first[:formatted_address]
      else
        json.dig(:candidates).sort_by { |candidate|
          next if candidate&.dig(:geometry, :location).blank?
          distance(loc, candidate.dig(:geometry, :location).values)
        }.first&.dig(:formatted_address)
      end
    end
  end

  # Find contact at [lat,lng]
  def near(coord, near_threshold=0.001)
    return [] unless coord.compact.length == 2

    contacts.find { |details|
      next unless details.loc&.compact&.length == 2

      distance(details.loc, coord) <= near_threshold
    }
  end

  # Get [lat,lng] from address
  # def geocode(address)
  # end

  # Get address from [lat,lng]
  def reverse_geocode(loc, get: :name)
    return "Herriman" unless Rails.env.production?

    Rails.cache.fetch("reverse_geocode(#{loc.map { |l| l.round(2) }.join(",")},#{get})") do
      ::Jarvis.say("Geocoding #{loc.join(",")},#{get}")
      url = "https://maps.googleapis.com/maps/api/geocode/json?latlng=#{loc.join(",")}&key=#{ENV["PORTFOLIO_GMAPS_PAID_KEY"]}"
      res = RestClient.get(url)
      json = JSON.parse(res.body, symbolize_names: true)

      case get
      when :name
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
