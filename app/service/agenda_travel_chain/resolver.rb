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

      latlng = address_book.geocode(text)
      return nil if latlng.blank?

      { address: text.to_s.strip, lat: latlng[0], lng: latlng[1] }
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
