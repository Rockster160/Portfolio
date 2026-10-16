class Jil
  # The listener terms that compute an answer instead of comparing text,
  # written `name(args)` - see Jil::ListenerMatch#term_hit and the "Functions"
  # section of docs/jil_listener_syntax.md.
  #
  # Each one answers `call(args, node)` with true, false, or nil when `node`
  # (the payload, or the part of it the term's key path points at) doesn't
  # carry what it needs, and `fault(args)` with a sentence when the arguments
  # could never work, so a broken term is refused when the listener is saved
  # rather than sitting there matching nothing.
  module ListenerFunctions
    module_function

    def [](name)
      REGISTRY[name.to_s.downcase.to_sym]
    end

    def names
      REGISTRY.keys
    end

    # `near(lat lng radius)`: the payload's `lat`/`lng` within `radius` of that
    # point. The radius is metres by default, or `km`/`mi`; left off, it is
    # NEAR_DEFAULT_M, about one building and its parking lot.
    #
    # Coordinates rather than a place name because a name drifts - a place gets
    # renamed, two contacts share an address, the phone reverse-geocodes to the
    # town - and a point doesn't.
    module Near
      module_function

      NEAR_DEFAULT_M = 165
      EARTH_RADIUS_M = 6_371_000.0
      UNITS = { "" => 1, "m" => 1, "km" => 1000, "mi" => 1609.344 }.freeze
      NUMBER_RX = /-?\d+(?:\.\d+)?/
      RADIUS_RX = /\A(?<n>\d+(?:\.\d+)?)(?<unit>m|km|mi)?\z/i

      # The term for a point, so code writing one never builds the string itself.
      def term(loc, meters=NEAR_DEFAULT_M)
        lat, lng = Array(loc).map(&:to_f)
        "near(#{lat} #{lng} #{meters.round}m)"
      end

      def parse(args)
        parts = args.to_s.split(/[\s,]+/).compact_blank
        return nil unless parts.length.between?(2, 3)
        return nil unless parts.first(2).all? { |part| part.match?(/\A#{NUMBER_RX}\z/) }

        lat, lng = parts.first(2).map(&:to_f)
        return nil unless lat.abs <= 90 && lng.abs <= 180

        radius = parts[2] ? RADIUS_RX.match(parts[2]) : nil
        return nil if parts[2] && radius.nil?

        meters = radius ? radius[:n].to_f * UNITS.fetch(radius[:unit].to_s.downcase) : NEAR_DEFAULT_M
        { loc: [lat, lng], meters: meters }
      end

      def fault(args)
        return nil if parse(args)

        "`near(#{args})` needs a latitude, a longitude and optionally a radius - " \
          "`near(40.53 -112.01 200m)`."
      end

      def call(args, node)
        want = parse(args)
        return nil if want.nil?

        here = [node[:lat], node[:lng]]
        return nil unless here.all? { |val| val.to_s.match?(/\A#{NUMBER_RX}\z/) }

        here = here.map(&:to_f)
        return nil if here.all?(&:zero?)

        meters_between(here, want[:loc]) <= want[:meters]
      end

      def meters_between(here, there)
        lat1, lng1, lat2, lng2 = [*here, *there].map { |deg| deg * Math::PI / 180 }
        a = (Math.sin((lat2 - lat1) / 2)**2) + (Math.cos(lat1) * Math.cos(lat2) * (Math.sin((lng2 - lng1) / 2)**2))
        2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(a))
      end
    end

    REGISTRY = { near: Near }.freeze
  end
end
