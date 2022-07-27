module AddressBook
  module_function

  def contacts
    @contacts ||= JSON.parse(File.read("address_book.json"), symbolize_names: true)
  end

  def home
    contact_by_name("Home")
  end

  def distance(c1, c2)
    # √[(x₂ - x₁)² + (y₂ - y₁)²]
    Math.sqrt((c2[0] - c1[0])**2 + (c2[1] - c1[1])**2)
  end

  def contact_by_name(name)
    name = name.to_s.downcase
    # Exact match (no casing)
    found = contacts.find { |details| details[:name].to_s.downcase == name }
    # Match without special chars
    found ||= contacts.find { |details|
      details[:name].to_s.downcase.gsub(/[^ a-z0-9]/, "") == name.gsub(/[^ a-z0-9]/, "")
    }
    # Match with only letters
    found ||= contacts.find { |details|
      details[:name].to_s.downcase.gsub(/[^a-z]/, "") == name.gsub(/[^a-z]/, "")
    }
  end

  def address_from_name(name, loc=nil)
    # TODO: This should default to the current location of phone
    loc ||= home[:loc]
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

  def near(coord, distance=0.001)
    return [] unless coord.compact.length == 2

    contacts.find { |details| distance(details[:loc], coord) <= distance }
  end

  def reverse_geocode(loc)
    return "Herriman" unless Rails.env.production?

    url = "https://maps.googleapis.com/maps/api/geocode/json?latlng=#{loc.join(",")}&key=#{ENV["PORTFOLIO_GMAPS_PAID_KEY"]}"
    res = RestClient.get(url)
    json = JSON.parse(res.body, symbolize_names: true)
    json.dig(:results, 0, :address_components)&.find { |comp|
      comp[:types] == ["locality", "political"]
    }&.dig(:short_name)
  end
end
