class LocationCache
  extend DistanceHelper

  def self.driving?
    !!User.me.jarvis_caches.dig(:driving, :is_driving)
  end

  def self.driving=(bool)
    # Called after Set
    PrettyLogger.info("Before:#{driving?} SetTo:#{bool}")
    return if driving? == bool
    PrettyLogger.info("Triggering Travel")
    departed = bool

    ::Jarvis.trigger(
      :travel,
      {
        coord: departed ? nil : recent_locations[-1], # If arrived, show current
        from: recent_locations[departed ? -1 : -2], # If arrived, show previous, otherwise current
        location: current_location_name, # Most recent stopped
        action: departed ? :departed : :arrived,
        timestamp: Time.current,
      },
      scope: { user_id: User.me.id }
    )

    User.me.jarvis_caches.dig_set(:driving, :is_driving, departed)
  end

  def self.nearby_contact(loc=nil)
    User.me.address_book.contact_by_loc(loc || last_location[:loc])
  end

  def self.current_location_name(loc=nil)
    nearby_contact(loc)&.name || lookup_location_name(loc)
  end

  def self.lookup_location_name(loc=nil)
    User.me.address_book.reverse_geocode(loc || last_location[:loc], get: :city)
  end

  def self.last_location
    recent_locations.last
  end

  def self.last_coord
    recent_locations.last&.dig(:loc)
  end

  def self.recent_locations
    User.me.jarvis_caches.dig(:driving, :recent_locations) || []
  end

  def self.set(loc, at=nil)
    at ||= (Time.current.to_f * 1000).round # Tesla sends ms since epoch instead of seconds
    locations = recent_locations
    loc = loc.map(&:to_f)

    return if locations.length >= 3 && near?(locations.last[:loc], loc)

    locations = locations.push({ loc: loc, at: at, name: current_location_name(loc) }).last(3)
    User.me.jarvis_caches.dig_set(:driving, :recent_locations, locations)
  end
end
