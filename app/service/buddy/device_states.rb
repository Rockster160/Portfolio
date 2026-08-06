module Buddy
  # What the house is doing right now, off the Home Assistant state cache.
  #
  # The cache is `UserCache` key `hass` on the owner, written by the HASS
  # automations as states change — device name to `{state, at, battery}`:
  #
  #     { "Doggy Sensor" => { "state" => "close", "at" => 1786032406, "battery" => 100 } }
  #
  # It's read for anyone in the owner's household, not just the owner, because
  # it describes the house they all live in. Whether the doggy door is shut is
  # not his private information.
  #
  # This closes a gap that produced confident wrong answers. Asked "is the
  # laundry gate open?", the companion's only route was `jil_functions` — a live
  # call that changes nothing but costs a round trip and needs the right
  # function to exist and be described as a READ. When one didn't, the answer
  # was "I can't check that from here", which was false: the state was sitting
  # in a cache the whole time.
  #
  # Cached state is not live state, so every reading carries how old it is. A
  # sensor that last spoke four hours ago is a different answer from one that
  # spoke a minute ago, and collapsing the two is how "the door is closed"
  # becomes a lie.
  module DeviceStates
    module_function

    KEY = :hass

    # Past this, a reading is history rather than a state. Still reported — the
    # last thing a sensor said is usually the answer — but the phrasing has to
    # stop implying "right now", which is what STALE_AFTER drives in the prompt.
    STALE_AFTER = 2.hours

    def available?(user)
      owner = ::User.me
      return false if owner.nil? || user.nil?
      return true if user.id == owner.id

      owner.chore_household_id.present? && user.chore_household_id == owner.chore_household_id
    end

    def raw(user)
      return {} unless available?(user)

      cached = ::User.me.caches.get(KEY)
      cached.is_a?(Hash) ? cached : {}
    rescue StandardError => e
      Rails.logger.warn("[Buddy::DeviceStates] #{e.class}: #{e.message}")
      {}
    end

    # Newest first: the thing that just changed is nearly always the thing being
    # asked about.
    #
    # Keys are read indifferently on purpose. UserCache round-trips everything
    # through its serializer and hands back SYMBOLS, while the HASS automations
    # write strings — so reading `info["state"]` works right up until the value
    # has been through the cache once, which is always.
    def for_user(user, now: Time.current)
      raw(user).filter_map { |device, info|
        next unless info.is_a?(Hash)

        row = info.with_indifferent_access
        at  = seen_at(row)
        {
          device:  device.to_s,
          state:   row[:state].presence,
          ago:     (ago_phrase(at, now) if at),
          stale:   (at.nil? || at < now - STALE_AFTER),
          battery: row[:battery],
        }.compact
      }.sort_by { |row| [row[:stale] ? 1 : 0, row[:device]] }
    end

    # The reading for one device, by name or by anything the household glossary
    # says means that device. "The doggy door" is not what the sensor is called.
    def find(user, phrase)
      rows = for_user(user)
      needle = phrase.to_s.downcase.strip
      return nil if needle.empty?

      exact = rows.detect { |r| r[:device].downcase == needle }
      return exact if exact

      aliased = glossary_name(user, phrase)
      return rows.detect { |r| r[:device].casecmp(aliased).zero? } if aliased

      rows.detect { |r| r[:device].downcase.include?(needle) || needle.include?(r[:device].downcase) }
    end

    # A glossary entry of kind `device` maps household words onto the name the
    # sensor actually reports under.
    def glossary_name(user, phrase)
      term = ::HouseholdGlossaryTerm.lookup(user.chore_household, phrase)
      return nil if term.nil? || !term.kind_device?

      term.meaning.to_s.strip.presence
    end

    def seen_at(row)
      stamp = row[:at]
      return nil if stamp.blank?

      Time.zone.at(stamp.to_f)
    rescue StandardError
      nil
    end

    def ago_phrase(at, now)
      seconds = (now - at).to_i
      case seconds
      when ..90        then "just now"
      when 91..5_400   then "#{(seconds / 60.0).round} min ago"
      when 5_401..(36 * 3_600) then "#{(seconds / 3_600.0).round}h ago"
      else "#{(seconds / 86_400.0).round}d ago"
      end
    end
  end
end
