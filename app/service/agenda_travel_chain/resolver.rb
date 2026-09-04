module AgendaTravelChain
  # Thin wrapper over AddressBook that adds an event-row-level fingerprint
  # short-circuit: once we've resolved an address+arrival for an event, we
  # won't hit AddressBook (or its Rails.cache) again until the inputs that
  # drive the resolution actually change. This is what keeps the worker
  # idempotent + cheap on every unrelated save.
  #
  # Resolution surface:
  #   resolve_location(text)            → { address:, lat:, lng: }  | nil
  #   travel_seconds(from, to, at)      → integer | nil
  #   home                              → User.me.address_book.home  (delegates)
  #
  # All Google round-trips funnel through AddressBook#geocode and
  # AddressBook#traveltime_seconds — so caching, throttling, and the
  # NON_TRAVELABLE rejects all stay in one place.
  class Resolver
    include CoordCalculator

    # Cross-state happens. Cross-ocean does not.
    #
    # Prod agenda_item 1054, 3 Sep: "Neurodiversity Clinic" - a bare venue name
    # with no city - was geocoded to -37.879, 145.023, which is Melbourne,
    # Australia. There is no driving route across the Pacific, so travel_seconds
    # came back nil, no `agenda-travel-prepare` and no `agenda-travel-go` were
    # ever created, and a 2 PM appointment with 10 minutes' arrive-early got no
    # leave-by and no time-to-go. Nothing logged; the only symptom was a briefing
    # that quietly left the drive out.
    #
    # Measured from where the person IS (`current_loc` - the live coord, falling
    # back to home), so a trip doesn't make every venue around them implausible.
    # A wrong geocode is off by thousands of miles, not hundreds.
    MAX_DRIVE_MILES = 1_000
    FEET_PER_MILE   = 5_280.0

    def initialize(user)
      @user = user
    end

    def home
      address_book.home
    end

    def resolve_location(text)
      return nil if text.blank?
      return nil if ::AddressBook.non_travelable?(text)

      # 1. Contact match wins — "Sarah's House", "Mom", "Costco" (if the
      # user has a Costco contact). AddressBook#match_contact handles
      # possessive/plural normalisation. We geocode the contact's street
      # rather than the raw input so the lat/lng matches the address text
      # we hand back.
      contact_addr = address_book.match_contact(text)&.primary_address&.street
      if contact_addr.present?
        latlng = address_book.geocode(contact_addr)
        return { address: contact_addr, lat: latlng[0], lng: latlng[1] } if latlng.present?
        # Contact matched but their address won't geocode — fall through
        # rather than return nil so we still try Places.
      end

      # 2. Direct geocode — full street addresses resolve cleanly here.
      latlng = address_book.geocode(text)
      address = text.to_s.strip

      # A confident answer on the wrong continent is worse than no answer: it is
      # written as sticky metadata and the whole leave-by chain is then built on
      # top of a drive that can't exist. Dropping it here falls through to
      # Places, which is biased to where they are and is the right tool for a
      # bare venue name anyway.
      latlng = nil if latlng.present? && !plausible_drive?(text, latlng)

      if latlng.blank?
        # 3. Places `findplacefromtext` biased to the user's current
        # location. Catches casual chain names ("Costco", "Texas
        # Roadhouse") that Geocoding can't disambiguate. Both calls
        # share the same upstream Google response (Rails.cache
        # short-circuit), so this is one round-trip in steady state.
        address = address_book.nearest_from_name(text, extract: :address)
        return nil if address.blank?

        latlng = address_book.nearest_from_name(text, extract: :loc)
        return nil if latlng.blank?
        # Places is biased to their location so this is unlikely, but the
        # invariant is worth having whole: nothing gets written as a place to
        # drive to that is further away than anyone drives.
        return nil unless plausible_drive?(text, latlng)
      end

      { address: address, lat: latlng[0], lng: latlng[1] }
    end

    # at: optional Time / epoch; Google uses traffic-aware drive times when
    # the departure is in the future.
    def travel_seconds(from, to, at: nil)
      return nil if from.blank? || to.blank?

      address_book.traveltime_seconds(to, from, at: at)
    end

    def travel_minutes(from, to, at: nil)
      secs = travel_seconds(from, to, at: at)
      return nil if secs.nil?

      (secs / 60.0).ceil
    end

    private

    # Nothing to measure against means nothing to disbelieve — an install with
    # no home contact and no location cache gets the old behavior rather than a
    # blanket refusal.
    def plausible_drive?(text, latlng)
      origin = Array(address_book.current_loc).compact
      return true if origin.length < 2 || Array(latlng).compact.length < 2

      miles = distance_between(origin, latlng) / FEET_PER_MILE
      return true if miles <= MAX_DRIVE_MILES

      Rails.logger.warn(
        "[AgendaTravelChain::Resolver] refusing #{text.inspect} at #{latlng.inspect}: " \
        "#{miles.round} miles from #{origin.inspect} is not a drive",
      )
      false
    end

    def address_book
      @address_book ||= @user.address_book
    end
  end
end
