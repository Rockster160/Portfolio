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

    def address_book
      @address_book ||= @user.address_book
    end
  end
end
