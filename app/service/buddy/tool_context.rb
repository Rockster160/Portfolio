module Buddy
  # Passed to every tool's confirm/label/execute/receipt proc. Wraps the
  # user + current proposal state and centralizes the "resolve a fuzzy name
  # to a domain record" logic so tool files stay short.
  #
  # Resolvers return the top candidate silently; ambiguity is the persona's
  # problem (it should ask the user via a follow-up message).
  class ToolContext
    attr_reader :user, :proposal, :conversation

    def initialize(user, proposal: nil, conversation: nil)
      @user         = user
      @proposal     = proposal
      @conversation = conversation
    end

    # The pet's display name for the thread this tool ran in ("Byte"/"Moss"/
    # "Suki"). Falls back to the user's default when a conversation isn't in scope.
    def buddy_name
      theme = conversation&.buddy_theme || ByteConversation.default_theme_for(user)
      ByteConversation.display_name_for(theme)
    end

    # ---- chores ----

    # How far a typo may be from a real chore name before we stop guessing,
    # as a share of what was typed. `complete_chore` runs the moment it
    # resolves, so a wrong guess writes a completion for a chore nobody did:
    # unbounded, the nearest-neighbour fallback answered "waters" with
    # "Shower" — the least-bad of a bad field, and 5 edits away from what was
    # asked for. Roughly a third lets ordinary typos through ("brush teth")
    # while a word that simply isn't there resolves to nothing, which raises,
    # which makes Buddy ask instead of act.
    FUZZY_TOLERANCE = 0.34

    def resolve_chore(name)
      return nil if name.blank?

      needle     = name.to_s.downcase.strip
      candidates = user.accessible_chores.to_a
      exact      = candidates.find { |c| c.name.to_s.downcase == needle }
      return exact if exact

      best_contained(candidates, needle) || nearest_name(candidates, needle)
    end

    def resolve_chore_completion(chore_or_name, hint: :last)
      resolve_chore_completions(chore_or_name, hint: hint, limit: 1).first
    end

    # Newest-first. `limit` is what "put that note on both waters" needs:
    # `complete_chore(count: 2)` writes two separate rows, so an edit aimed at
    # "the ones you just did" has to reach more than the single latest.
    def resolve_chore_completions(chore_or_name, hint: :last, limit: 1)
      chore = chore_or_name.is_a?(Chore) ? chore_or_name : resolve_chore(chore_or_name)
      return [] if chore.nil?

      scope = ChoreCompletion.where(chore_id: chore.id, user_id: user.id).order(completed_at: :desc)
      scope = case hint.to_sym
      when :today     then scope.where(completed_at: user.perceived_today.beginning_of_day..)
      when :yesterday then scope.where(completed_at: (user.perceived_today - 1.day).all_day)
      else                 scope
      end
      scope.limit([limit.to_i, 1].max).to_a
    end

    # ---- lists ----

    def resolve_list(name)
      user.list_by_name(name.to_s)
    end

    def resolve_list_item(list_or_name, item_name)
      list = list_or_name.is_a?(List) ? list_or_name : resolve_list(list_or_name)
      return nil if list.nil?

      list.list_items.by_formatted_name(item_name.to_s)
    end

    # ---- events ----

    def resolve_event(name, hint: :last)
      return nil if name.blank?

      scope = user.action_events.where("LOWER(name) LIKE ?", "%#{name.to_s.downcase}%")
      case hint.to_s
      when "today"        then scope.where(timestamp: user.perceived_today.beginning_of_day..).order(timestamp: :desc).first
      when "yesterday"    then scope.where(timestamp: (user.perceived_today - 1.day).all_day).order(timestamp: :desc).first
      when "this morning" then scope.where(timestamp: user.perceived_today.beginning_of_day..user.perceived_today.change(hour: 12)).order(timestamp: :desc).first
      when /^\d+$/        then scope.find_by(id: hint.to_i)
      else                     scope.order(timestamp: :desc).first
      end
    end

    # ---- agenda ----

    def resolve_agenda_item(title, hint_date: nil)
      return nil if title.blank?

      needle = title.to_s.downcase.strip
      # Editable rather than owned: a jointly-run calendar like "Ours" belongs to
      # one of the two people, so scoping to ownership meant the other one could
      # never edit anything on it — including something they'd just moved there.
      agendas = user.editable_agendas.pluck(:id)
      scope = AgendaItem.where(agenda_id: agendas)
      scope = scope.where("LOWER(name) LIKE ?", "%#{needle}%")
      if hint_date.present?
        day = (Time.zone.parse(hint_date.to_s) rescue nil)
        scope = scope.where(start_at: day.beginning_of_day...day.end_of_day) if day
      end
      scope.order(start_at: :asc).first
    end

    # An item the person already has that looks like the one being added — same
    # title, same day, starting within the hour. That combination is much more
    # often a move they phrased as an add than two real things, so add_agenda_item
    # mentions it rather than quietly making a second copy.
    def existing_agenda_twin(title, at)
      return nil if title.blank?

      start = at.respond_to?(:strftime) ? at : resolve_time(at)
      return nil if start.nil?

      AgendaItem
        .where(agenda_id: user.editable_agendas.select(:id))
        .where("LOWER(name) = ?", title.to_s.downcase.strip)
        .where(start_at: (start - 1.hour)..(start + 1.hour))
        .where.not(status: :cancelled)
        .order(:start_at)
        .first
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ToolContext] twin lookup failed: #{e.class}: #{e.message}")
      nil
    end

    # A watch already listening for exactly this condition. Same purpose as
    # existing_agenda_twin: surface it before Buddy speaks, so a second one is a
    # choice rather than a surprise.
    #
    # It's the invisible ones that hurt. A "deploy" watch carries an empty match,
    # so every deploy watch is identical by construction and there is nothing in
    # the request to tell one from another - prod had a two-day-old one-shot
    # nobody remembered sitting behind a fresh repeating one, and a single deploy
    # pinged twice. Two reminders for arriving home ("shower", "do laundry") hit
    # this too and are perfectly legitimate; the point is to mention it, never to
    # refuse.
    def existing_watch_twin(scope, match, owner: user)
      BuddyWatch.active.where(user_id: owner.id, trigger_scope: scope.to_s, match: (match || {})).order(:id).last
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ToolContext] watch twin lookup failed: #{e.class}: #{e.message}")
      nil
    end

    # ---- places ----

    # Resolve a spoken place ("costco", "the gym") to its canonical known
    # name via the user's AddressBook, so a location watch matches the
    # name the arrival trigger actually carries (contact name, e.g.
    # "Costco"). Falls back to the raw name when there's no known place.
    def resolve_place(name)
      return nil if name.blank?

      user.address_book.match_contact(name)&.name || name.to_s.strip
    end

    # ---- agendas / calendars ----

    # Pick which calendar an agenda item lands on. Considers every LOCAL agenda
    # the person can write to (their own + editor-shared, e.g. a jointly-run
    # "Ours"). Google-synced agendas are excluded here - those need the app's
    # mirror-first add flow, which this tool doesn't do. Blank name → the
    # primary local agenda (lowest id). A named calendar fuzzy-matches so
    # "our" / "ours" / "our schedule" all reach "Ours 💕"; no match falls back
    # to the primary (and the confirm card shows the name so it's catchable).
    def writable_agendas
      user.editable_agendas.reject(&:managed_externally?).sort_by(&:id)
    end

    # `strict:` governs what an unmatched NAME does. Adding falls back to the
    # default and shows the calendar on the confirm card, which is catchable.
    # Moving can't do that: silently relocating something to the wrong calendar
    # is worse than refusing, so edit_agenda_item asks for nil instead.
    def resolve_writable_agenda(name, strict: false)
      agendas = writable_agendas
      return nil if agendas.empty?

      default = default_agenda(agendas)
      q = normalize_calendar(name)
      return default if q.blank?

      match = (
        agendas.find { |a| normalize_calendar(a.name) == q } ||
        agendas.find { |a| normalize_calendar(a.name).include?(q) || q.include?(normalize_calendar(a.name)) } ||
        agendas.find { |a| calendar_token_match?(normalize_calendar(a.name), q) }
      )
      return match if match

      strict ? nil : default
    end

    # Where an item goes when nobody names a calendar. The person's own choice
    # if they've made one (AgendaPreference), otherwise the oldest writable
    # calendar — which is how "put it on Ours by default" used to be impossible
    # to honour no matter how many times it was said.
    def default_agenda(agendas=writable_agendas)
      return nil if agendas.empty?

      preferred = AgendaPreference.for(user).default_agenda_id
      agendas.find { |a| a.id == preferred.to_i } || agendas.first
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ToolContext] default agenda lookup failed: #{e.class}: #{e.message}")
      agendas.first
    end

    # Resolve a spoken place to { "name" =>, "loc" => [lat,lng] } for a
    # location watch. `loc` is the whole point: matching is coordinate-based,
    # so the watch fires no matter which NAME the arrival trigger resolves to
    # (one physical spot carries several names - "TMS" and "Ketamine" both
    # happen at "Serenity"). Local-first cascade:
    #   1. a contact with this name -> its address coordinates
    #   2. an agenda item with this name -> resolve ITS location to coordinates
    #      (that location is often a different contact or a street for the same
    #      spot - this is how "TMS" reaches Serenity's coords)
    #   3. name only, no coords (matching falls back to name equality)
    def resolve_place_location(name)
      name = name.to_s.strip
      return { "name" => "", "known" => false } if name.blank?

      # 1. A known contact - its coordinates if it has them; still "known" by
      #    name if it doesn't (the arrival trigger resolves to the same contact
      #    name, so name-equality matching still fires).
      contact = user.address_book.match_contact(name)
      if contact
        addr = contact.primary_address
        return place_hash(contact.name, addr&.street, addr&.loc, known: true)
      end

      # 2. The person's calendar - an event with this name carries the address
      #    for the spot (this is the "TMS -> Serenity" bridge).
      location = agenda_location_for(name)
      if location.present?
        via = coords_for_location(location)
        return place_hash(name, location, via, known: valid_loc?(via))
      end

      # 3. A general place we can geocode (a real spot, not a private nickname).
      geo = user.address_book.geocode(name)
      return place_hash(name, nil, geo, known: true) if valid_loc?(geo)

      # 4. Nothing resolved - we genuinely don't know where this is.
      place_hash(name, nil, nil, known: false)
    end

    # Resolve a place for a WEATHER lookup to { label, lat, lng }. Blank →
    # home. Otherwise reuse the place cascade (contact → agenda), then fall
    # back to geocoding the raw string so general places / cities that aren't
    # saved anywhere ("the Plunge in Alpine", "Moab") still resolve. Returns
    # just { label } (no coords) when nothing resolves — the tool reports that
    # it couldn't find the spot rather than guessing.
    def resolve_weather_place(name)
      name = name.to_s.strip
      if name.blank?
        return { "label" => "home", "lat" => WeatherService::HOME_LAT, "lng" => WeatherService::HOME_LNG }
      end

      # resolve_place_location already cascades contact → agenda → geocode.
      place = resolve_place_location(name)
      label = place["name"].presence || name
      loc   = place["loc"]
      return { "label" => label } unless valid_loc?(loc)

      { "label" => label, "lat" => loc[0], "lng" => loc[1] }
    end

    # ---- times ----

    def resolve_time(iso)
      Time.zone.parse(iso.to_s)
    rescue ArgumentError
      nil
    end

    # Friendly future phrasing for a receipt/confirmation, in the user's zone:
    #   today            → "at 6:01pm"
    #   tomorrow         → "tomorrow at 6:01pm"
    #   within this week → "this Wednesday at 6:01pm"
    #   next week        → "next Wednesday at 6:01pm"
    #   further out      → "on Jul 15 at 6:01pm"
    # On-the-hour times drop the minutes ("6pm"). all_day drops the time.
    def friendly_future(time, all_day: false)
      return "later" if time.nil?

      local = time.in_time_zone(user.timezone)
      # Calendar-relative here (NOT the 3am perceived rollover the agenda uses):
      # this phrases a reminder's CLOCK time, so a 6pm reminder set at 1am should
      # read "at 6pm" (later today), never "tomorrow".
      today = Time.current.in_time_zone(user.timezone).to_date
      days  = (local.to_date - today).to_i

      day_prefix = case days
      when 0     then ""
      when 1     then "tomorrow "
      when 2..6  then "this #{local.strftime("%A")} "
      when 7..13 then "next #{local.strftime("%A")} "
      else            "on #{local.strftime("%b %-d")} "
      end

      return (day_prefix.strip.presence || "today").to_s.strip if all_day

      time_str = local.strftime("%-I:%M%P").sub(":00", "")  # "6:01pm" / "6pm"
      "#{day_prefix}at #{time_str}"
    end

    # ---- household ----

    def resolve_household_user(name)
      return user if name.to_s.downcase.in?(%w[me myself i])
      return nil if user.chore_household_id.nil?

      wanted     = name.to_s.downcase.strip
      candidates = User.where(id: user.chore_household&.member_user_ids || [])
      candidates.find { |u| u.first_name.to_s.downcase == wanted } ||
        candidates.find { |u| u.username.to_s.downcase.include?(wanted) }
    end

    private

    # Chores whose NAME contains what was typed, best first. Enumeration order
    # used to decide this, and enumeration order is arbitrary: "water" matches
    # both "Wash Water Bowls" (id 5) and "8oz Water" (id 9), so the lower id
    # won and someone logging that they drank something got three bowl-washings
    # marked off instead.
    #
    # Rank by how much of the name the needle accounts for. "water" is most of
    # "8oz Water" and a fifth of "Wash Water Bowls", which is the instinct a
    # person uses without thinking: the shorter name is the one that's ABOUT
    # the thing you said, the longer one merely mentions it.
    def best_contained(candidates, needle)
      hits = candidates.select { |c| c.name.to_s.downcase.include?(needle) }
      return nil if hits.empty?

      hits.max_by { |c| needle.length.to_f / c.name.to_s.length }
    end

    # Nearest name by edit distance, but only when it's near ENOUGH to be a
    # typo of what they said rather than the closest thing in an empty field.
    def nearest_name(candidates, needle)
      best = candidates.min_by { |c| levenshtein(c.name.to_s.downcase, needle) }
      return nil if best.nil?

      best if levenshtein(best.name.to_s.downcase, needle) <= [(needle.length * FUZZY_TOLERANCE).round, 1].max
    end

    # A watch's stored place: coordinates are what matching uses; name is for
    # display; address is kept for legibility and as a human-readable record of
    # which spot the coords point at. Blank fields are dropped so the hash stays
    # tidy for name-only fallbacks.
    def place_hash(name, address, loc, known: true)
      place = { "name" => name.to_s.strip, "known" => known }
      place["address"] = address.to_s.strip if address.to_s.strip.present?
      place["loc"] = loc if valid_loc?(loc)
      place
    end

    def valid_loc?(loc)
      loc.is_a?(Array) && loc.compact.length == 2 && loc.all? { |v| v.to_f.nonzero? }
    end

    # Strip emoji/punctuation so "Ours 💕" → "ours".
    def normalize_calendar(str)
      str.to_s.downcase.gsub(/[^a-z0-9 ]+/, " ").squeeze(" ").strip
    end

    # Loose token match so "our"/"our schedule" hits "Ours": any word (3+ chars)
    # on one side is a prefix of a word on the other ("our" ⟂ "ours").
    def calendar_token_match?(agenda_name, query)
      aw = agenda_name.split.select { |w| w.length >= 3 }
      qw = query.split.select { |w| w.length >= 3 }
      aw.any? { |x| qw.any? { |y| x.start_with?(y) || y.start_with?(x) } }
    end

    # The location string of the agenda item whose name matches `name`, picking
    # the occurrence closest to now (past or future) so a recurring appointment
    # resolves to its usual spot. This is the "TMS -> Serenity" bridge: the
    # person books these as calendar events, and the event carries the address.
    def agenda_location_for(name)
      agenda_ids = Agenda.where(user_id: user.id).pluck(:id)
      return nil if agenda_ids.empty?

      AgendaItem.where(agenda_id: agenda_ids)
        .where("name ILIKE ?", name.to_s.strip)
        .where.not(location: [nil, ""])
        .order(Arel.sql("ABS(EXTRACT(EPOCH FROM (start_at - now())))"))
        .limit(1)
        .pick(:location)
    end

    # Turn an agenda location string into coordinates, local-first: it may be a
    # contact name ("Serenity") or a street ("3300 N Triumph Blvd ..."). Only
    # falls back to a (cached) geocode when neither is on file.
    def coords_for_location(location)
      ab = user.address_book
      loc = ab.match_contact(location)&.primary_address&.loc
      return loc if valid_loc?(loc)

      loc = user.addresses.where("street ILIKE ?", location.to_s.strip).first&.loc
      return loc if valid_loc?(loc)

      geo = ab.geocode(location)
      geo if valid_loc?(geo)
    end

    def levenshtein(a, b)
      m, n = a.length, b.length
      return n if m.zero?
      return m if n.zero?

      d = Array.new(m + 1) { Array.new(n + 1, 0) }
      (0..m).each { |i| d[i][0] = i }
      (0..n).each { |j| d[0][j] = j }
      (1..m).each { |i|
        (1..n).each { |j|
          cost = a[i - 1] == b[j - 1] ? 0 : 1
          d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
        }
      }
      d[m][n]
    end
  end
end
