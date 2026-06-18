module AgendaTravelChain
  # Walks a chain head forward, expanding each event's before/after override
  # lists, and yields the ordered waypoint list the chain's prepare task
  # should hand to Tesla. Home is appended as the final waypoint when the
  # trip doesn't already end there.
  #
  # Output entry:
  #   { name:, address:, lat:, lng: }
  #
  # `name` is human-friendly ("Costco", "Home", or the event's `name`).
  # `lat`/`lng` come from cached lat/lng on metadata when available, else
  # from a fresh geocode (rare — happens only for before/after waypoints
  # the user typed but never had on an event before).
  class TripBuilder
    def initialize(head_item)
      @head = head_item
      @user = head_item.user
      @resolver = Resolver.new(@user)
    end

    def waypoints
      stops = chain_events.flat_map { |evt| event_with_overrides(evt) }
      stops = with_home_terminus(stops)
      stops.compact.uniq { |s| [s[:lat], s[:lng], s[:name]] }
    end

    private

    def chain_events
      items = [@head]
      loop do
        succ_id = items.last.metadata.dig("travel", "chain_successor_id")
        break unless succ_id

        nxt = ::AgendaItem.locate_for_user(succ_id, @user)
        break unless nxt

        items << nxt
      end
      items
    end

    def event_with_overrides(evt)
      overrides = evt.metadata.dig("travel", "overrides") || {}
      [
        *Array(overrides["before"]).map { |txt| waypoint_for_text(txt) },
        waypoint_for_event(evt),
        *Array(overrides["after"]).map { |txt| waypoint_for_text(txt) },
      ]
    end

    def waypoint_for_event(evt)
      t = evt.metadata["travel"] || {}
      lat = t["location_lat"]
      lng = t["location_lng"]
      if lat.nil? || lng.nil?
        res = @resolver.resolve_location(evt.location)
        return nil unless res

        lat = res[:lat]
        lng = res[:lng]
      end
      { name: evt.name.to_s, address: evt.location.to_s, lat: lat, lng: lng }
    end

    def waypoint_for_text(text)
      res = @resolver.resolve_location(text)
      return nil unless res

      { name: text.to_s, address: res[:address], lat: res[:lat], lng: res[:lng] }
    end

    # Auto-append Home unless the trip already ends with it. Compares by name
    # (case-insensitive) — Home is a regular contact in AddressBook, so its
    # geocoded address matches a `Home` override identically.
    def with_home_terminus(stops)
      home = @resolver.home
      return stops if home.blank? || home.loc.blank?

      last = stops.last
      return stops if last && last[:name].to_s.casecmp("Home").zero?

      stops + [{ name: "Home", address: home.street.to_s, lat: home.loc[0], lng: home.loc[1] }]
    end
  end
end
