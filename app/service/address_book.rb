module AddressBook
  module_function

  def contacts
    @contacts ||= JSON.parse(File.read("address_book.json")).with_indifferent_access
  end

  def distance(c1, c2)
    # √[(x₂ - x₁)² + (y₂ - y₁)²]
    Math.sqrt((c2[0] - c1[0])**2 + (c2[1] - c1[1])**2)
  end

  def contact_by_name(name)
    name = name.to_s.downcase
    found = contacts.find { |place_name, _details| place_name.to_s.downcase == name }
    found ||= contacts.find { |place_name, _details|
      place_name.to_s.downcase.gsub(/[^ a-z0-9]/, "") == name.gsub(/[^ a-z0-9]/, "")
    }
    found ||= contacts.find { |place_name, _details|
      place_name.to_s.downcase.gsub(/[^a-z]/, "") == name.gsub(/[^a-z]/, "")
    }
  end

  def near(coord, distance=0.001)
    return [] unless coord.compact.length == 2

    contacts.find { |name, details| distance(details[:loc], coord) <= distance }
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
