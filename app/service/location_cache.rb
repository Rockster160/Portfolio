class LocationCache
  extend DistanceHelper

  def self.driving?
    !!User.me.jarvis_cache.get(:is_driving)
  end

  def self.driving=(bool)
    return if driving? == bool

    ::Jarvis.trigger(
      :travel,
      {
        coord: last_location,
        location: location_name,
        action: bool ? :departed : :arrived,
        timestamp: Time.current,
      },
      scope: { user_id: User.me.id }
    )
    notify(bool)

    User.me.jarvis_cache.set(:is_driving, bool)
  end

  def self.nearby_contact
    User.me.address_book.contact_by_loc(last_location[:loc])
  end

  def self.notify(bool)
    location = location_name.presence || last_location[:loc]
    Jarvis.ping("#{bool ? 'Departing' : 'Arrived at'} #{location}")
  end

  def self.location_name
    nearby_contact&.name || lookup_location_name
  end

  def self.lookup_location_name
    User.me.address_book.reverse_geocode(last_location[:loc], get: :city)
  end

  def self.last_location
    recent_locations.last
  end

  def self.recent_locations
    User.me.jarvis_cache.get(:recent_locations) || []
  end

  def self.set(loc, at)
    locations = recent_locations

    return if locations.length >= 3 && near?(locations.last[:loc], loc)

    locations = locations.push({ loc: loc, at: at, name: location_name }).last(3)
    User.me.jarvis_cache.set(:recent_locations, locations)
  end
end
