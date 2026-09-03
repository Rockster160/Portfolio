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

    # Edit distance, on the singleton because it belongs to nothing in
    # particular - Buddy::Inventory ranks box names with the same one, and two
    # copies of a Levenshtein is two places for a fuzzy match to drift.
    def self.levenshtein(a, b)
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

    # Words that say HOW MANY, not WHICH.
    #
    # "another water" is water, again - the chore is `water` and the rest is the
    # request wrapped around it. Matching runs one way only (does a chore NAME
    # contain what they said), so every one of these wrappers used to miss:
    # "water" resolved and "another water", "one more water" and "water again"
    # did not, which is the shape a person's own words arrive in.
    REPEAT_WORDS = /
      \b(?: another | again | one \s+ more | 1 \s+ more | more | extra
          | additional | an \s+ extra | a \s+ second | second )\b
    /xi

    def resolve_chore(name)
      return nil if name.blank?

      candidates = user.accessible_chores.to_a
      needle     = name.to_s.downcase.strip
      direct     = match_chore(candidates, needle)
      return direct if direct

      # Only once the name as given has failed, so a chore genuinely CALLED
      # "Second Coat" or "Extra Laundry" is still found by its own name first.
      variants(needle).each { |variant|
        found = match_chore(candidates, variant)
        return found if found
      }

      nil
    end

    # What else the same request could be called. Repeat words come off first,
    # then a plural is folded back to the singular - "waters" is the same ask as
    # "water", and it's the one the FUZZY_TOLERANCE comment records answering to
    # "Shower" back when the fallback was wide enough to reach it.
    def variants(needle)
      trimmed = needle.gsub(REPEAT_WORDS, " ").squish
      [trimmed, trimmed.singularize].uniq.reject { |v| v.blank? || v == needle }
    end

    def match_chore(candidates, needle)
      exact = candidates.find { |c| c.name.to_s.downcase == needle }
      return exact if exact

      best_contained(candidates, needle) || by_alias(candidates, needle) ||
        nearest_name(candidates, needle)
    end

    # The other names a chore goes by, which until now nothing read.
    #
    # Prod 4705, 11:51: "Mark refill drinks done an hour ago" wrote a completion
    # against chore 83, `Refill Item`. He meant 42, `Restock Soda`, whose
    # `aliases` column is ["refill", "drinks", "fridge"] - both of his words, in
    # the column, verbatim. `aliases_array` has existed on the model, been
    # serialized, and been editable in the chore form the whole time; the
    # matcher only ever looked at `name`, so the one chore he could not have
    # named more clearly was the one chore that could not be found.
    #
    # BELOW `best_contained`, so nothing that resolves today changes: an alias
    # is an extra door, not a replacement for the front one. "refill" still
    # reaches `Refill Item` by its name.
    #
    # ONE match or none. "refill" alone is an alias of four different chores,
    # and picking the lowest id out of those is the false-record `FUZZY_TOLERANCE`
    # exists to prevent - so several matches declines, falls through, and comes
    # out as the disambiguation card `no_chore!` already builds.
    def by_alias(candidates, needle)
      hits = candidates.select { |c| handles_cover?(c, needle) }
      hits.one? ? hits.first : nil
    end

    # Is what they said made up ENTIRELY of this chore's own handles?
    #
    # Greedy, longest handle first, and whole-word: each one that appears in
    # what they said is struck out, and it matches only if nothing meaningful
    # survives. "refill drinks" against 42 strikes "refill" and then "drinks"
    # and comes out empty. Against 121 (`Restock Protein`, aliases "refill" and
    # "protein drinks") it strikes "refill" and leaves "drinks" standing, which
    # is the whole reason this is a covering test rather than a word-overlap
    # score - the near miss has to LOSE, not merely rank second.
    def handles_cover?(chore, needle)
      handles = (chore.aliases_array + [chore.name.to_s]).filter_map { |h| h.to_s.downcase.strip.presence }
      rest    = needle.dup
      handles.sort_by { |h| -h.length }.each { |h|
        rest = rest.gsub(/(?<![a-z0-9])#{Regexp.escape(h)}(?![a-z0-9])/, " ")
      }
      rest != needle && significant_words(rest).empty?
    end

    # Words that carry no chore in them, so a needle made only of these has
    # nothing to suggest from.
    CHORE_STOPWORDS = (
      %w[a an the one more another other some any my our it that this] +
      %w[again done did do next last of for to and or]
    ).freeze

    # What they might have meant, for when nothing resolved.
    #
    # Returning nil rather than guessing is correct and stays that way - see
    # FUZZY_TOLERANCE, where "waters" answering to "Shower" is the thing being
    # prevented, and a completion written against the wrong chore is a false
    # record nobody can see is false. What was missing is the other half: the
    # model got back the bare fact that its string missed, and nothing else.
    #
    # Prod 3802-3808. "Water cup yesterday" resolved (the model passed the exact
    # name, `8oz Water`, and two waters went on). Forty seconds later "Add it as
    # one more" and "No, mark another water done yesterday" both failed, because
    # the model passed the person's own phrasing that time and `resolve_chore`
    # only ever asks whether a chore NAME contains the needle - never the other
    # way round, so every superset of a real name misses. "one more water",
    # "another water" and "water cup" all resolve to nothing while bare "water"
    # resolves cleanly.
    #
    # Twice Buddy could do no better than ask which chore was meant, and the
    # third attempt gave up on chores entirely and wrote an ActionEvent instead
    # (msg 3805), reporting it as though the chore had been marked. The water
    # asked for twice was never recorded anywhere.
    #
    # So: name the near misses in the failure. A retry then picks from a list
    # instead of guessing again, and it happens inside the same turn.
    def chore_suggestions(name, limit: 4)
      words = significant_words(name)
      return [] if words.empty?

      scored = user.accessible_chores.to_a.filter_map { |c|
        # Aliases count here for the same reason they count in `by_alias`: a
        # chore whose alias list holds both of the words they used cannot be
        # allowed to sit outside the near-miss list while one sharing a single
        # word tops it. Prod 4705 - `Restock Soda` was unreachable from
        # "refill drinks" by NAME, so the list it wasn't in is what the model
        # picked its second guess from, and it picked wrong.
        parts  = significant_words("#{c.name} #{c.aliases_array.join(' ')}")
        shared = words.count { |w| parts.any? { |p| p.start_with?(w) || w.start_with?(p) } }
        [shared, c.name.to_s] if shared.positive?
      }
      # Most words in common first; the shortest name breaks a tie, on the same
      # reasoning as best_contained - the least padding around the match.
      scored.sort_by { |shared, chore_name| [-shared, chore_name.length] }.first(limit).map(&:last)
    end

    # The failure `complete_chore` and `edit_chore` raise, with those near
    # misses folded in. One place, because a resolve that misses reads the same
    # whichever tool asked.
    def no_chore_error(name, suffix: nil)
      near = chore_suggestions(name)
      base = "no chore matching #{name.inspect}"
      base = "#{base} #{suffix}" if suffix.present?
      return base if near.empty?

      "#{base} - the closest names are #{near.join(", ")}. " \
        "Call again with one of those EXACTLY if one is what they meant, " \
        "or ask them which. Never substitute another tool for the chore."
    end

    # The failure to RAISE, which is the sentence above plus the candidates
    # themselves.
    #
    # Prod 4495: "Log load dishwasher" could have been `Light Load Dishes` or
    # `Medium~Normal Load Dishes`, and the old answer was a sentence asking
    # which - so she had to type a chore name back at it. Buddy::Disambiguation
    # puts them on screen and a tap runs the completion.
    #
    # ONE near miss gets a card too. "I couldn't find anything called X - did
    # you mean Y?" with a button under it is one tap; the same sentence without
    # one is a whole corrected message. The words still say what happened, so
    # the button adds a shortcut rather than hiding anything.
    def no_chore!(name, suffix: nil, arg: :chore)
      message = no_chore_error(name, suffix: suffix)
      near    = chore_suggestions(name)
      raise message if near.empty?

      raise ::Buddy::Ambiguous.new(
        message,
        arg:     arg,
        prompt:  chore_prompt(name, near),
        options: near.map { |chore_name| { value: chore_name, label: chore_name } },
      )
    end

    def chore_prompt(name, near)
      opener = "I couldn't find anything called #{name.to_s.strip.inspect}"
      return "#{opener} - did you mean #{near.first}?" if near.length == 1

      "#{opener}. Which one did you mean?"
    end

    # Whole words worth matching on. Short ones are dropped rather than
    # stopworded: two-letter fragments match INSIDE longer words ("as" sits in
    # "wash"), which is how "add it as one more" came back suggesting a
    # bowl-washing. Prefix comparison rather than equality so a plural or a
    # participle still counts - "waters" and "watering" are both "water".
    def significant_words(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).select { |w| w.length >= 3 } - CHORE_STOPWORDS
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
      when :today     then scope.where(completed_at: Buddy::Day.range(user).first..)
      when :yesterday then scope.where(completed_at: yesterday_range(user))
      else                 scope
      end
      scope.limit([limit.to_i, 1].max).to_a
    end

    # ---- lists ----

    def resolve_list(name)
      found = user.list_by_name(name.to_s)
      ambiguous_list!(name) if found.nil?
      found
    end

    # A list name that MISSED, with more than one list it could have been.
    #
    # `List.by_name_for_user` matches one way only - the phrase they said has to
    # CONTAIN the list's name - so "put it on the grocery list" resolves to
    # nothing at all when the lists are called `Grocery Staples` and `Grocery
    # Costco`, and the old answer was "no list matching \"grocery\"" with both
    # of them sitting right there. Same shape as the chore resolver's near
    # misses, and the same answer: put them on screen.
    #
    # Whole words on the LEADING edge, the rule `starts_on_a_word?` exists for,
    # so `grocery` reaches `Grocery Staples` and `cery` reaches nothing.
    def ambiguous_list!(name)
      needle = name.to_s.downcase.strip
      return if needle.blank?

      hits = user.ordered_lists.select { |list| starts_on_a_word?(list.name, needle) }
      return if hits.empty?

      shown  = hits.first(::Buddy::Disambiguation::MAX_OPTIONS)
      names  = shown.map { |list| list.name.to_s }
      opener = "I couldn't find a list called #{name.to_s.strip.inspect}"
      raise ::Buddy::Ambiguous.new(
        "no list matching #{name.to_s.strip.inspect} - the closest are #{names.to_sentence}. " \
        "Call again with one of those EXACTLY if one is what they meant, or ask them which",
        arg:     :list,
        prompt:  (names.length == 1 ? "#{opener} - did you mean #{names.first}?" : "#{opener}. Which one did you mean?"),
        options: shown.map { |list| { value: list.name.to_s, label: list.name.to_s } },
      )
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
      when "today"        then scope.where(timestamp: Buddy::Day.range(user).first..).order(timestamp: :desc).first
      when "yesterday"    then scope.where(timestamp: yesterday_range(user)).order(timestamp: :desc).first
      when "this morning" then scope.where(timestamp: Buddy::Day.range(user).first...Buddy::Day.at(user, hour: 12)).order(timestamp: :desc).first
      when /^\d+$/        then scope.find_by(id: hint.to_i)
      else                     scope.order(timestamp: :desc).first
      end
    end

    # The perceived day before this one, as a half-open range of real Times.
    #
    # `Date#all_day` and `Date#beginning_of_day` both resolve in `Time.zone`,
    # which is UTC app-wide — so on a UTC-6 account "today" started at 6pm the
    # previous evening and "yesterday" was a window six hours out of step. Every
    # boundary here goes through Buddy::Day, which builds them in the person's
    # own zone and rolls the day at 3am like the rest of Buddy does.
    def yesterday_range(user)
      start, finish = Buddy::Day.range(user, date: user.perceived_today - 1.day)
      start...finish
    end

    # ---- agenda ----

    # How far ahead to look for the next occurrence of a rule that has no rows.
    # A weekly series answers inside a week; a monthly one needs the month.
    SERIES_LOOKAHEAD = 45.days

    # `editable: false` for a LOOK. A partner's calendar is shared in as a viewer,
    # so it is out of `editable_agendas` — correct for a write, and wrong for
    # "how long does it take her to get home from yoga", which is a question
    # about the asker's own evening. See check_travel_time.
    def resolve_agenda_item(title, hint_date: nil, editable: true)
      return nil if title.blank?

      needle = title.to_s.downcase.strip
      # Editable rather than owned: a jointly-run calendar like "Ours" belongs to
      # one of the two people, so scoping to ownership meant the other one could
      # never edit anything on it — including something they'd just moved there.
      agendas = (editable ? user.editable_agendas : user.accessible_agendas).pluck(:id)
      scope = AgendaItem.where(agenda_id: agendas)
      scope = scope.where("LOWER(name) LIKE ?", "%#{needle}%")
      if hint_date.present?
        # Midnight to midnight in THEIR zone. Parsed in Time.zone (UTC) it named
        # the six hours either side of the wrong boundary, so "the dentist thing
        # on Tuesday" could match Monday evening's item instead.
        day = (Time.zone.parse(hint_date.to_s)&.to_date rescue nil)
        if day
          from = Buddy::Day.at(user, hour: 0, date: day)
          scope = scope.where(start_at: from...(from + 1.day))
        end
      end
      found = scope.order(start_at: :asc).to_a
      ambiguous_agenda_item!(found, title) if found.length > 1

      found.first || unmaterialized_occurrence(agendas, needle, hint_date)
    end

    # Two DIFFERENT things whose names both carry what they said, which is a
    # choice; the same thing on four dates is not - a recurring dentist matching
    # its own next four occurrences has one right answer and it is the soonest.
    # So this keys on the name, and only raises when the names actually differ.
    #
    # `edit_agenda_item` is the only caller, which is the one where landing on
    # the wrong row rewrites something nobody asked about.
    def ambiguous_agenda_item!(found, title)
      by_name = found.group_by { |i| i.name.to_s.downcase }
      return if by_name.length < 2

      shown = by_name.values.map(&:first).first(::Buddy::Disambiguation::MAX_OPTIONS)
      raise ::Buddy::Ambiguous.new(
        "more than one thing on the calendar matches #{title.to_s.strip.inspect} - " \
        "#{shown.map { |i| i.name.to_s }.to_sentence}. Ask which one",
        arg:     :item,
        prompt:  "More than one thing on the calendar matches #{title.to_s.strip.inspect}. Which one did you mean?",
        options: shown.map { |item|
          { value: item.name.to_s, label: item.name.to_s, description: agenda_when(item) }
        },
      )
    end

    # When it is, in their own words, so two items with similar names are told
    # apart by the thing that actually separates them.
    def agenda_when(item)
      return nil if item.start_at.blank?

      local = item.start_at.in_time_zone(user.timezone)
      item.all_day ? local.strftime("%a %-d %b") : local.strftime("%a %-d %b, %-l:%M %p")
    end

    # A series occurrence that has no row yet.
    #
    # AgendaSchedule::MATERIALIZE_WINDOW only reaches 30 hours ahead, so four of
    # the five dinners added on prod 4462 existed purely as rules - and this
    # method's AgendaItem query is why "I'd need you to point at that specific
    # row" was the answer three times running. There was no row to point at.
    #
    # Returns an UNSAVED phantom, the same one the calendar renders, carrying
    # its `agenda_schedule`. edit_agenda_item reads that: an occurrence with no
    # row can only be changed through the rule that generates it.
    def unmaterialized_occurrence(agenda_ids, needle, hint_date)
      day  = (Time.zone.parse(hint_date.to_s)&.to_date rescue nil) if hint_date.present?
      from = day || Buddy::Day.today(user)
      schedules = AgendaSchedule
        .where(agenda_id: agenda_ids)
        .where("LOWER(name) LIKE ?", "%#{needle}%")
        .active_between(from, from + SERIES_LOOKAHEAD)
        .order(:id)
        .to_a
      return nil if schedules.empty?

      dates = day ? [day] : (from..(from + SERIES_LOOKAHEAD)).to_a
      dates.each { |date|
        hit = schedules.find { |sc| sc.matches?(date) }
        return hit.build_phantom(date) if hit
      }
      nil
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ToolContext] series lookup failed: #{e.class}: #{e.message}")
      nil
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
    # Two watches are twins when they'd fire on the same thing. For a named
    # trigger that's the match hash; for a hand-written one it's the listener,
    # because every custom watch carries an empty match and comparing those
    # would call any two watches on the same scope duplicates.
    def existing_watch_twin(scope, match, owner: user, listener: nil)
      scoped = BuddyWatch.active.where(user_id: owner.id, trigger_scope: scope.to_s)
      scoped = listener.present? ? scoped.where(listener: listener) : scoped.where(listener: nil, match: (match || {}))
      scoped.order(:id).last
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ToolContext] watch twin lookup failed: #{e.class}: #{e.message}")
      nil
    end

    # The OTHER custom watches already armed on this trigger.
    #
    # A twin is decided by string equality on the listener, so it can only ever
    # catch an exact repeat — and a CORRECTION is never one. Prod 3743 set a
    # doorbell-RING watch; thirty seconds later 3746 said "No, not doorbell
    # ring. Again. I want to know the next time the doorbell SEES a person."
    # That wrote a second watch with a different listener, nothing cancelled the
    # first, and 74 minutes on it delivered the exact ping he'd refused, in the
    # words he'd rejected.
    #
    # Deliberately NOT a similarity score over the listener strings. Whether two
    # of them mean the same sensor isn't decidable from the text: a literal and
    # a regex can name one thing (`location:doorbell`, `location:/^Doorbell$/`),
    # and two listeners sharing a term can be on different ones. Guessing would
    # trade a miss for a confident wrong answer.
    #
    # Bounded by RECENT instead, which is what actually separates a correction
    # from a second opinion. Watching the Claude list and the Shopping list are
    # both `item` and have nothing to do with each other; warning on every pair
    # that shares a scope would put a cancel offer in front of watches nobody
    # asked about. A correction, though, lands seconds later - these two were 31
    # apart - so the window is the signal, not the string.
    RECENT_SIBLING = 10.minutes

    def sibling_watches(scope, listener, owner: user, limit: 3)
      return [] if listener.blank?

      scoped = BuddyWatch.active.where(user_id: owner.id, trigger_scope: scope.to_s)
      scoped = scoped.where.not(listener: [nil, "", listener])
      scoped = scoped.where(created_at: RECENT_SIBLING.ago..)
      scoped.order(:id).last(limit)
    rescue StandardError => e
      Rails.logger.warn("[Buddy::ToolContext] sibling watch lookup failed: #{e.class}: #{e.message}")
      []
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

    # `strict:` governs what an unmatched NAME does: nil, for the caller to
    # raise on, rather than the default calendar.
    #
    # Both agenda tools pass it. Add used not to, on the reasoning that the
    # fallback was catchable because the confirm card names the calendar - and
    # that lost on prod 4463, where five dinners went to Alchemibluum under a
    # reply saying "the Dinners calendar" because the model wrote back the
    # argument it passed rather than the receipt it got. A name nobody has is a
    # question, not a default.
    #
    # A BLANK name still resolves to the default, which is what "put it on the
    # calendar" means and is unaffected by this.
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

    # ---- jil ----

    # Fuzzy-match a Jil automation this person is allowed to fire, by name.
    # Returns { id:, name:, listener:, scope:, plain: } or nil.
    #
    # `plain` is whether the listener is a bare scope token. Those fire on the
    # name alone; anything with `:` filters needs a payload built to satisfy
    # them, so a caller with nowhere to supply one (a watch action, a saved
    # button) has to refuse rather than wire up something that never fires.
    def resolve_jil_trigger(name)
      q = name.to_s.downcase.strip
      return nil if q.blank?

      candidates = user.accessible_tasks.buddy_visible.where.not(listener: [nil, ""])
        .pluck(:id, :name, :listener)
        .reject { |_, _, listener| listener.to_s.match?(/(^|\s)function\(/i) }

      match = candidates.find { |_, n, _| n.downcase == q }
      match ||= candidates.find { |_, n, _| n.downcase.start_with?(q) }
      match ||= candidates.find { |_, n, _| n.downcase.include?(q) }
      return nil if match.nil?

      id, task_name, listener = match
      {
        id:       id,
        name:     task_name,
        listener: listener,
        scope:    listener.to_s.strip.split(":").first,
        plain:    listener.to_s.strip.match?(/\A[a-zA-Z][a-zA-Z0-9_-]*\z/),
      }
    end

    # ---- times ----

    # Every `iso_time` arg lands here eventually. Goes through parse_in_zone
    # rather than a bare Time.zone.parse because Time.zone is UTC app-wide: a
    # naive "2026-08-03T16:45:00" — the most natural thing for the model to
    # write — used to become 16:45 UTC, which is 10:45 AM on a UTC-6 calendar.
    def resolve_time(iso)
      parse_in_zone(iso.to_s)
    end

    # A time for something going ON the calendar, with the 12-hour slip undone.
    #
    # A calendar entry is nearly always ahead of you, and the two ways the model
    # gets a same-day time wrong both land it in the morning: writing 04:45 when
    # it means 16:45, and converting to UTC with the offset the wrong way round
    # (which, at UTC-6, is the same 12-hour error). Prod Aug 3: "move the shower
    # earlier" was answered with "Shower's now at 4:45 PM" and an `at` of
    # 10:45Z - 4:45 AM, eleven hours before the reply that announced it.
    #
    # Deliberately narrow. It can only ever touch a time that is TODAY, ALREADY
    # PAST, and still today once shifted - so a deliberate back-date to
    # yesterday, an ordinary future time, and a late-evening entry are all
    # untouched. Runs in `confirm` so the checklist row shows the corrected
    # time; a wrong guess is one untick away.
    # The END of a day named loosely - "today", "tomorrow", "3 days", "friday",
    # or a plain date. Used for bounding how long a watch stays armed, where
    # "only today" has to mean all of today rather than this instant tomorrow.
    #
    # Returns nil for anything unreadable so the caller can say so; quietly
    # defaulting would arm a watch forever that they asked to stop.
    RELATIVE_DAYS_RX = /\A(?:in\s+)?(\d+)\s*(day|days|week|weeks)\z/i
    WEEKDAY_NAMES    = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

    # A DAY, phrased the way someone would say it out loud. The sibling of
    # `friendly_future`, which phrases a clock time; this one is for a bound
    # ("until tonight") where the hour is noise.
    def friendly_day(time)
      return "later" if time.nil?

      local = time.in_time_zone(user.timezone).to_date
      case (local - Time.current.in_time_zone(user.timezone).to_date).to_i
      when ..0   then "tonight"
      when 1     then "tomorrow"
      when 2..6  then local.strftime("%A")
      else            local.strftime("%b %-e")
      end
    end

    def end_of_day_for(phrase)
      text = phrase.to_s.strip.downcase
      return nil if text.empty?

      zone  = Buddy::Day.zone(user)
      today = Time.current.in_time_zone(zone).to_date
      date  = (
        case text
        when "today", "tonight"      then today
        when "tomorrow"              then today + 1
        when "this week", "the week" then today.end_of_week(:sunday)
        else                              relative_or_named_day(text, today)
        end
      )
      return nil if date.nil?

      zone.parse(date.iso8601)&.end_of_day
    end

    def relative_or_named_day(text, today)
      if (match = RELATIVE_DAYS_RX.match(text))
        count = match[1].to_i
        return today + (match[2].start_with?("week") ? count.weeks : count.days)
      end

      index = WEEKDAY_NAMES.index(text.delete_prefix("next ").strip)
      return next_weekday(today, index) if index

      Date.parse(text) rescue nil
    end

    def next_weekday(today, index)
      date = today + 1
      date += 1 until date.wday == index
      date
    end

    # A time already gone today lands at NOW. Nothing is nudged forward.
    #
    # This used to add 12 hours, on the theory that "4:45" written at 5 PM meant
    # 16:45. It guessed wrong far more than it guessed right, and the wrong
    # guesses were invisible: prod 966 and 967 were "today, finish the living
    # room and bedroom" with no hour named anywhere, so the model wrote the wall
    # clock it had been handed, that resolved a few seconds later, and both items
    # landed at 11:11 PM. Half a day away from anything anyone said.
    #
    # An item at the current time is at worst where the conversation already is,
    # and it's visibly wrong if it's wrong. One half a day out reads as
    # deliberate and gets found at bedtime.
    def resolve_calendar_time(iso)
      time = resolve_time(iso)
      return nil if time.nil?

      now  = Time.current
      zone = Buddy::Day.zone(user)
      return time unless time < now && time.in_time_zone(zone).to_date == now.in_time_zone(zone).to_date

      now
    end

    # An explicit offset is authoritative; without one the string is their wall
    # clock, not the server's.
    HAS_OFFSET_RX = /[zZ]\z|[+-]\d{2}:?\d{2}\z/
    DATE_ONLY_RX  = /\A\d{4}-\d{2}-\d{2}\z/
    # What "no due date" looks like coming from the model.
    CLEAR_DUE     = %w[none clear never off null].freeze

    # A chore due DATE, as an instant inside the chore-day it names. Returns
    # :clear to unset one, or nil when there's nothing usable.
    #
    # Two traps here, and a bare date walks into both. Parsed in Time.zone
    # (UTC app-wide) "2026-08-05" is 6pm the previous evening locally — and the
    # chore day runs 4am to 4am, so even local midnight falls in the day BEFORE.
    # Either one marks a chore due a day early. A date on its own is therefore
    # anchored to the start of its chore day; anything naming a real clock time
    # is kept as the instant it names.
    def resolve_due(text)
      str = text.to_s.strip
      return nil if str.empty?
      return :clear if CLEAR_DUE.include?(str.downcase)

      time = parse_in_zone(str)
      return nil if time.nil?
      return time unless str.match?(DATE_ONLY_RX)

      ChoreDay.starts_at(time.to_date, user)
    end

    def parse_in_zone(str)
      str.match?(HAS_OFFSET_RX) ? Time.zone.parse(str) : Buddy::Day.zone(user).parse(str)
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
      hits = candidates.select { |c| starts_on_a_word?(c.name, needle) }
      return nil if hits.empty?

      hits.max_by { |c| needle.length.to_f / c.name.to_s.length }
    end

    # Does the name contain what they said STARTING at a word, rather than
    # anywhere at all?
    #
    # A bare include? lets a negating prefix disappear. Prod 4495, 09:25:
    # Chelsea said "Log load dishwasher" and `Unload Dishwasher` (78) was marked
    # done, because "unload dishwasher" contains "load dishwasher". Loading and
    # unloading are opposite jobs on the same appliance, and the two chores she
    # plausibly meant - `Light Load Dishes` and `Medium~Normal Load Dishes` -
    # were both in the roster. A completion written against the wrong chore is
    # the false record FUZZY_TOLERANCE exists to prevent, six lines up.
    #
    # The LEADING edge only. What comes after is ordinary inflection - "dish"
    # has to go on finding "Dishes" and "water" has to go on finding "Watering
    # the Beds" - and a suffix has never changed what a chore IS. A prefix does:
    # un-, re-, non-, dis- are the whole vocabulary of doing the opposite.
    def starts_on_a_word?(name, needle)
      name.to_s.downcase.match?(/(?<![a-z0-9])#{Regexp.escape(needle)}/)
    end

    # Nearest name by edit distance, but only when it's near ENOUGH to be a
    # typo of what they said rather than the closest thing in an empty field.
    #
    # The boundary rule above has to hold here too, or it changes nothing:
    # "unload dishwasher" is two edits from "load dishwasher" against a
    # tolerance of five, so the row best_contained just refused comes straight
    # back by the other route. A name carrying what they said with letters
    # glued to the front of it is not a typo of it - it is a different word.
    def nearest_name(candidates, needle)
      pool = candidates.reject { |c| glued_prefix?(c.name, needle) }
      best = pool.min_by { |c| levenshtein(c.name.to_s.downcase, needle) }
      return nil if best.nil?

      best if levenshtein(best.name.to_s.downcase, needle) <= [(needle.length * FUZZY_TOLERANCE).round, 1].max
    end

    def glued_prefix?(name, needle)
      name.to_s.downcase.include?(needle) && !starts_on_a_word?(name, needle)
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
      self.class.levenshtein(a, b)
    end
  end
end
