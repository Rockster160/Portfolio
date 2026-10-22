module RecordLinks
  # Carries a completion downhill.
  #
  #     event  ->  chore  ->  agenda  ->  list_item
  #
  # This is the Rails half of what Jil tasks 362, 365, 366, 370, 374, 382, 383
  # and 416 used to do. Both of the old uphill rules were dropped when this
  # replaced them, then brought back per pairing through `reverse`: by default
  # completing a chore writes no ActionEvent and adding a list item marks no chore
  # due, but a row flagged `reverse` opens the uphill reading too, so the pairing
  # reads as a two-way SYNC. The cron and button tasks that relied on the old
  # list->chore rule were converted to mark the chore due themselves, which pushes
  # the item back down the cascade and arrives in the same place.
  #
  # The two uphill rungs:
  #   * list_item -> chore (`on_item`): putting the item back marks the chore due.
  #     This also catches the SPOKEN path — "Add Pickup RX to Chores" is a
  #     sentence, not a task anybody could rewrite, and for an unscheduled
  #     `when_scheduled` chore the mark is the only thing that puts it on Today.
  #   * chore -> event (`sync_completion_event`): marking the chore done directly
  #     logs the event that would have completed it, so a board / chores-page /
  #     Buddy completion reads the same as logging the event. One event per
  #     completion, and only for an event that maps to exactly one chore — a
  #     shared event can't run up without ticking its other chores.
  #
  # Each runs only for a pairing explicitly marked `reverse`, so the cascade stays
  # one-way everywhere it was not deliberately opened. The Guard's revisit rule
  # and the +/-1s partner joins keep a two-way pairing from chasing its own tail.
  #
  # The behaviour that survived is deliberately identical to Jil's, including
  # the awkward parts, because these pairings run a real household and "slightly
  # different now" is worse than either old or new:
  #
  #   * Partners are matched on a +/-1 SECOND window around the timestamp. There
  #     is no foreign key between a ChoreCompletion and its ActionEvent — the
  #     clock IS the join key — which is why an edit has to be told the OLD time
  #     before it can find what to move.
  #   * A `changed` event that no longer matches its link DESTROYS the partner.
  #     Renaming an event out of a pairing means the completion it created
  #     should not survive it.
  #   * Every write is a no-op when the partner already says what it should.
  module Propagator
    module_function

    WINDOW = 1.second

    # How far back to look for the real event an uphill completion reproduces.
    # A daily medication is a handful of rows deep; this is the ceiling, not the
    # expectation.
    EXEMPLAR_SCAN = 100

    # Scopes that can start a cascade. One set lookup for everything else on the
    # bus, which is most of it.
    SCOPES = %w[event chore chore_completion item prompt].to_set.freeze

    # Hooked into Jil::Executor.trigger rather than onto each model's callbacks,
    # for the same reason Buddy::WatchMatcher is: the bus is the only place that
    # sees EVERY firing. Four paths write these records around the model hook
    # you'd otherwise reach for — ActionEventsController and Jarvis::Log fire
    # `:event`, and both list-item controllers fire `:item`.
    def dispatch(user, scope, payload)
      key = scope.to_s
      return unless SCOPES.include?(key)
      return if user.nil? || payload.nil?

      attrs   = overlay(payload)
      action  = (attrs[:action] || attrs["action"]).presence
      changes = attrs[:changes] || attrs["changes"]

      case key
      when "event"            then on_event(user, payload, action, changes: changes) if action
      when "chore"            then on_chore(user, payload, action) if action
      when "chore_completion" then on_completion(user, payload, action) if action
      when "item"             then on_item(user, attrs, action) if action
      when "prompt"           then on_prompt(user, payload, attrs)
      end
    rescue StandardError => e
      # A link is a convenience. It must never take down the automation, the
      # controller action, or the request that fired the trigger.
      Rails.logger.error("[RecordLinks] dispatch #{scope} failed: #{e.class}: #{e.message}")
      nil
    end

    def overlay(payload)
      return payload.symbolize_keys if payload.is_a?(Hash)

      attrs = payload.try(:execution_attrs)
      attrs.is_a?(Hash) ? attrs : {}
    end

    # ---- event -> (chore | agenda | list_item) ----

    def on_event(user, event, action, changes: nil)
      return if event.nil? || event.id.blank?

      act  = action.to_sym
      name = event.name.to_s
      # A rename has to reach the link keyed on the name the event USED to have.
      # Task 362 got that for free by looping the whole map every time; looking
      # up only the current name would strand the completion the old pairing
      # made under a name nobody watches.
      was  = (dig_change(changes, "name") if act == :changed)

      each_link(user, :event, [name, was]) { |link|
        matched = link.matches?(name, event.notes)
        run_event(user, link, event, act, changes, matched)
      }
    end

    def run_event(user, link, event, action, changes, matched)
      return unless matched || action == :changed

      case link.target_kind
      when "agenda" then (complete_agenda(user, link) if action == :added && matched)
      when "list_item" then (drop_item(user, link) if action == :added && matched)
      when "chore" then run_event_chore(user, link, event, action, changes, matched)
      end
    end

    def run_event_chore(user, link, event, action, changes, matched)
      chore = find_chore(user, link.target_name)
      return nil if chore.nil?

      if link.ask_who?
        return nil unless action == :added && matched

        # Don't ask when the doing is already attributed. A completion sitting in
        # this event's window means the chore was marked done DIRECTLY and this
        # event is the uphill record of that completion (see
        # `sync_completion_event`) - the completer is known, so there is nothing
        # to ask. An event logged on its own, with no completion yet, still
        # prompts. The completion can be a housemate's, so it's looked for
        # on everybody's account.
        # A stand-in from an earlier question attributes nothing.
        at = parse_time(event.timestamp)
        done = ::ChoreCompletion.where("chore_id = :id OR parent_chore_id = :id", id: chore.id)
        done = done.where(completed_at: (at - WINDOW)..(at + WINDOW)) if at
        return nil if at && done.exists?(["skipped_reason IS DISTINCT FROM ?", ::ChoreWhoDidIt::WAITING])

        return ask_who(user, link, event)
      end

      case action
      when :added   then (upsert_completion(user, chore, event) if matched)
      when :changed then changed_event(user, chore, event, changes, matched)
      when :removed then destroy_completion(user, chore, parse_time(event.timestamp))
      end
    end

    # An edit that moved the event carries the OLD timestamp, the only way to
    # find the partner before it moved. An edit that renamed the event out of
    # the pairing takes the partner with it.
    def changed_event(user, chore, event, changes, matched)
      prev_at = parse_time(dig_change(changes, "timestamp"))
      return upsert_completion(user, chore, event, prev_at: prev_at) if matched

      destroy_completion(user, chore, prev_at || parse_time(event.timestamp))
    end

    # ---- chore -> (agenda | list_item) ----

    # `marked_due` is the one non-completion signal that cascades: a chore
    # coming due puts its item ON the list, and completing it takes the item
    # off again. Both point the same way down the graph.
    def on_chore(user, chore, action)
      return if chore.nil?

      each_link(user, :chore, [chore.name]) { |link|
        next unless link.matches?(chore.name)

        case action.to_sym
        when :marked_due   then (add_item(user, link) if link.target_list_item?)
        when :unmarked_due then (drop_item(user, link) if link.target_list_item?)
        end
      }
    end

    def on_completion(user, completion, action)
      chore = completion&.chore
      name = chore&.name
      return if name.blank?

      each_link(user, :chore, [name]) { |link|
        next unless link.matches?(name)
        # The uphill event of a reverse pairing is handled ONCE below, not per
        # link, so a chore reached by several event names isn't logged under all
        # of them on a single completion.
        next if link.target_event?

        case action.to_sym
        when :completed
          link.target_agenda? ? complete_agenda(user, link) : drop_item(user, link)
        when :uncompleted
          # Undoing a completion puts the item back and un-ticks the agenda
          # task. Anything else leaves the person having to walk it back by
          # hand, which is the whole thing these links exist to avoid.
          link.target_agenda? ? uncomplete_agenda(user, link) : add_item(user, link)
        end
      }

      sync_completion_event(user, completion, action.to_sym)
    end

    # ---- chore -> event (the uphill half of a reverse event<->chore pairing) ----
    #
    # Logging an event completes the chore (downhill); this is the other way, so
    # the pairing reads as a real two-way sync: marking the chore done DIRECTLY
    # (a board, the chores page, Buddy, a credit button) logs the event that would
    # have completed it, and undoing the completion takes that event back.
    #
    # Two deliberate limits keep it honest:
    #   * ONE event per completion - the lowest-id pairing - so a chore several
    #     events can complete isn't logged under all of them at once.
    #   * only an event that maps to exactly ONE chore. A shared event ("Chore"
    #     completes several chores) can't round-trip: logging it here would tick
    #     the others too. Those stay one-way, whatever their reverse flag says.
    def sync_completion_event(user, completion, action)
      chore = completion.chore
      return if chore.nil?
      # The chore_completion trigger fans out to every household member so each
      # one's own automations fire. The event is logged once, by the one account
      # whose pairing it goes through (see `uphill_logger_id`).
      return unless user.id == uphill_logger_id(completion)

      link = uphill_link(user.id, chore)
      return if link.nil?

      case action
      when :completed   then log_completion_event(user, link, completion)
      when :uncompleted then remove_completion_event(user, link, completion)
      end
    end

    # The account that logs a completion's event: the completer's own pairing
    # first, then the recorder's, then any housemate's on a shared chore. A
    # pairing set up on one account still hears a chore its housemate marks
    # done, and the event goes where that account's automations listen.
    def uphill_logger_id(completion)
      chore = completion.chore
      ids = [completion.user_id, completion.recorded_by_user_id]
      ids += ::ChoreHousehold.find_by(id: chore.chore_household_id)&.member_user_ids.to_a.sort if chore.share_household?
      ids.compact.uniq.find { |id| uphill_link(id, chore) }
    end

    # The reverse pairing a completion of `chore` runs up through on this
    # account, or nil. Only an event that maps to exactly one chore - a shared
    # event can't round-trip without ticking the others.
    def uphill_link(user_id, chore)
      names = [chore.name, chore.parent_chore&.name].compact.map(&:to_s)
      all_up = RecordLink.live.source_event.target_chore.where(user_id: user_id).to_a
      paired = all_up.select { |l| l.reverse? && names.any? { |n| l.target_name.to_s.casecmp?(n) } }
      link = paired.min_by(&:id)
      return nil if link.nil?

      fan_out = all_up.count { |l|
        l.source_name.to_s.casecmp?(link.source_name.to_s) &&
          l.source_scope.to_s.casecmp?(link.source_scope.to_s)
      }
      fan_out > 1 ? nil : link
    end

    def log_completion_event(user, link, completion)
      at = parse_time(completion.completed_at) || Time.current
      # Idempotent: the completion may itself have been MADE by logging this event
      # (the downhill direction), in which case the event is already in the window
      # and logging a second one would be a phantom duplicate.
      return false unless event_partner(user, link.source_name, link.source_scope, at).nil?

      event = user.action_events.create!(uphill_event_attrs(user, link).merge(timestamp: at))
      ::ActionEventNotifier.notify(user, event, :added, auth: :link)
      true
    end

    # A "who did it?" stand-in is the chore done, so its event is logged as soon
    # as it's put up, not once somebody answers. The event's id goes on the
    # question before anything hears about it, so the event's own cascade sees
    # the question is already asked, the answer moves the event to the answered
    # time, and taking the stand-in back takes the event with it.
    def log_stand_in_event(user, completion, prompt)
      link = uphill_link(user.id, completion.chore)
      return nil if link.nil?

      at = completion.completed_at
      return nil unless event_partner(user, link.source_name, link.source_scope, at).nil?

      event = user.action_events.create!(uphill_event_attrs(user, link).merge(timestamp: at))
      prompt.update!(params: prompt.params.merge("event_id" => event.id, "scope" => link.source_scope, "logged_event" => true))
      ::ActionEventNotifier.notify(user, event, :added, auth: :link)
      event
    end

    # What to log when a direct completion runs uphill. `source_name` and
    # `source_scope` are MATCH PATTERNS, not content: a `starts_with` name, a
    # `contains` scope, or a blank scope over events that carry notes all throw
    # away whatever the pattern didn't need to match — which for a medication is
    # the dose. So reproduce the newest real event the pairing matches, and the
    # board press records what the person actually logs, dose and all. Only when
    # nothing has been logged yet does the pattern itself stand in.
    def uphill_event_attrs(user, link)
      template = exemplar_event(user, link)
      return { name: link.source_name, notes: link.source_scope.to_s } if template.nil?

      { name: template.name, notes: template.notes }
    end

    def exemplar_event(user, link)
      scoped = events_named_like(user, link).order(timestamp: :desc).limit(EXEMPLAR_SCAN)
      scoped.detect { |e| link.matches?(e.name, e.notes) }
    end

    # Narrow by name in SQL the way the link's own name match reads it, so the
    # scan covers the few events that could match rather than the whole history;
    # `matches?` then confirms both name and scope.
    def events_named_like(user, link)
      name = link.source_name.to_s.strip
      return user.action_events.none if name.empty?

      like = ActiveRecord::Base.sanitize_sql_like(name.downcase)
      case link.source_name_match.to_s
      when "starts_with" then user.action_events.where("LOWER(name) LIKE ?", "#{like}%")
      when "contains"    then user.action_events.where("LOWER(name) LIKE ?", "%#{like}%")
      else                    user.action_events.where("LOWER(name) = ?", name.downcase)
      end
    end

    def remove_completion_event(user, link, completion)
      at = parse_time(completion.completed_at)
      event = event_partner(user, link.source_name, link.source_scope, at)
      return false if event.nil?

      event.destroy!
      ::ActionEventNotifier.notify(user, event, :removed, auth: :link)
      true
    end

    # The event that partners a completion: same name and scope, within the same
    # +/-1s window the completion side joins on. `scope` lands in the event's
    # notes, which is what `matches?` reads a logged event's scope from.
    def event_partner(user, name, scope, at)
      return nil if at.blank?

      scoped = user.action_events
        .where(name: name, timestamp: (at - WINDOW)..(at + WINDOW))
        .order(:timestamp).to_a
      wanted = scope.to_s
      scoped.find { |e| e.notes.to_s.strip.casecmp?(wanted.strip) } || (scoped.first if wanted.empty?)
    end

    # ---- list_item -> chore (reverse pairings only) ----

    # The one rung that runs UPHILL. Putting the item back on the list is how a
    # person says the chore needs doing again, which is what Jil task 382 did
    # before the cascade was made one-way.
    #
    # Only `:added` acts. Taking an item OFF a list is not a claim that the
    # chore was done — it is as often a tidy-up — and `unmark_due` on a removal
    # would quietly undo a mark somebody made on purpose.
    #
    # Nothing stops this pointing straight back at `on_chore`'s `add_item`
    # except `Guard`, which is exactly the pair it was written for: the item
    # endpoint is already visited by the time the mark cascades back down, so
    # item -> chore -> item stops on the second item.
    def on_item(user, attrs, action)
      return unless action.to_sym == :added

      name = fetch(attrs, :name).to_s
      return if name.blank?

      each_link(user, :list_item, [name]) { |link|
        next unless link.target_chore?
        next unless link.matches?(name, item_list_name(attrs))

        mark_chore_due(user, link)
      }
    end

    # The scope a list-item link is matched on is the LIST, which arrives
    # nested because that is the shape `ListItem#jil_serialize` gives every
    # `:item` listener. A link scoped to Chores must not fire for the same
    # words typed onto Todo.
    def item_list_name(attrs)
      list = fetch(attrs, :list)
      list.is_a?(Hash) ? fetch(list, :name).to_s : nil
    end

    # Idempotent for the same reason `Jil::Methods::Chore#mark_due` is: a chore
    # already stamped writes nothing, so no `chore:marked_due` fires and the
    # cascade has nothing to carry back down. Guard would stop the loop anyway;
    # this stops the pointless write that starts it.
    def mark_chore_due(user, link)
      chore = find_chore(user, link.target_name)
      return false if chore.nil? || chore.marked_due?

      chore.update!(marked_due_at: Time.current)
      true
    end

    # ---- link iteration ----

    # `names` is a list because a rename has two. Each is visited separately, so
    # the guard treats them as distinct endpoints and both get their chance.
    def each_link(user, kind, names)
      Array(names).compact_blank.uniq { |n| n.to_s.downcase }.each do |name|
        Guard.visiting([kind.to_sym, name.to_s.downcase]) {
          links_for(user, kind).each do |link|
            yield(link)
          rescue StandardError => e
            Rails.logger.error("[RecordLinks] link ##{link.id} failed: #{e.class}: #{e.message}")
          end
        }
      end
    end

    # Downhill links sourced here, plus any uphill one deliberately pointed back
    # at this kind. `reverse` is additive: the row keeps its downhill reading
    # and gains the uphill one, so a `reverse` pairing appears in both halves of
    # this and runs both ways off the same row.
    def links_for(user, kind)
      RecordLink.sourced_from(user, kind).to_a +
        RecordLink.reversed_from(user, kind).map { |l| flipped(l) }
    end

    # A reverse link read the way the rules expect: source is what fired.
    def flipped(link)
      link.dup.tap { |f|
        f.id = link.id
        f.source_kind = link.target_kind
        f.source_name = link.target_name
        f.source_scope = link.target_scope
        f.target_kind = link.source_kind
        f.target_name = link.source_name
        f.target_scope = link.source_scope
      }
    end

    # ---- chore completions ----

    def upsert_completion(user, chore, event, prev_at: nil)
      # Down one level when this chore has been split per person. A link names
      # a chore, and once "Teeth" becomes a container holding one Teeth each,
      # the name still resolves to the container while the thing that needs
      # ticking is theirs. Resolved here rather than in `find_chore` because
      # the actor is only known at the write: `answered` completes for whoever
      # the prompt named, who is usually not the person whose links these are.
      chore = chore.completion_leaf_for(user)
      at   = parse_time(event.timestamp) || Time.current
      note = event.notes.to_s.presence
      partner = completion_partner(user, chore, prev_at) || completion_partner(user, chore, at)

      if partner
        desired = { completed_at: at, day_key: ChoreDay.current(user, at: at), note: note }
        return false if completion_says?(partner, desired)

        partner.update!(desired.compact)
        return true
      end

      completion = ::ChoreCompleter.new(chore, user, at: at).call.completion
      completion.update!(note: note) if note.present? && completion&.note.to_s != note
      true
    end

    def destroy_completion(user, chore, at)
      # Same redirect as the write, or a deleted event hunts for its partner on
      # the container and never finds the row it made on the leaf.
      partner = completion_partner(user, chore.completion_leaf_for(user), at)
      return false if partner.nil?

      partner.destroy!
      true
    end

    # The completion an event stands for. A chore marked done on a housemate's
    # behalf is credited to them while its event is logged on this account, so
    # their completion is the partner too; looking only at this account's own
    # completions made a second one and paid the chore twice. Their own row is
    # still preferred when both exist.
    def completion_partner(user, chore, at)
      return nil if chore.nil? || at.blank?

      scope = ::ChoreCompletion.where(chore_id: chore.id, completed_at: (at - WINDOW)..(at + WINDOW))
      scope.order(Arel.sql(::ChoreCompletion.sanitize_sql(["user_id = ? DESC", user.id])), :completed_at).first
    end

    def completion_says?(comp, desired)
      return false if comp.completed_at.blank? || desired[:completed_at].blank?
      return false unless (comp.completed_at.to_i - desired[:completed_at].to_i).abs < 1

      comp.note.to_s == desired[:note].to_s
    end

    # ---- list items ----

    def add_item(user, link)
      list = ::List.by_name_for_user(link.target_scope, user)
      return false if list.nil?

      list.list_items.add(link.target_name)
      true
    end

    def drop_item(user, link)
      list = ::List.by_name_for_user(link.target_scope, user)
      return false if list.nil?

      list.list_items.remove(link.target_name)
      true
    end

    # ---- agenda ----

    # Tasks 370 and 374 wrote this as `Agenda.search("name::X is:today
    # is:incomplete")`. Same query as scopes: today's window, a calendar this
    # person can see, not cancelled, not already ticked. `target_scope` of
    # "overdue" reproduces 370, which swept overdue Shower items too.
    def complete_agenda(user, link)
      agenda_items(user, link, :incomplete).each(&:complete!).any?
    rescue StandardError => e
      Rails.logger.warn("[RecordLinks] agenda sync #{link.target_name.inspect}: #{e.class}: #{e.message}")
      false
    end

    def uncomplete_agenda(user, link)
      agenda_items(user, link, :completed).each(&:uncomplete!).any?
    rescue StandardError
      false
    end

    def agenda_items(user, link, state)
      sources = ::Buddy::Context.agenda_source_map(user)
      return [] if sources.empty?

      scope = ::AgendaItem.where(agenda_id: sources.keys).not_cancelled
        .where("LOWER(name) = ?", link.target_name.to_s.downcase)
      scope = state == :incomplete ? scope.incomplete : scope.where.not(completed_at: nil)
      scope = link.target_scope.to_s == "overdue" ? scope.where(start_at: ..Time.current.end_of_day) : scope.today
      scope.to_a
    end

    # ---- ask who ----

    # Only a person can say who did it - the button that logged it may be on a
    # wall everybody uses. See ChoreWhoDidIt, which every such question goes
    # through.
    def ask_who(user, link, event)
      # The bus can deliver `added` twice for one row (a retried job, a fan-out),
      # and a second identical prompt is a second thing to dismiss.
      return false if asked_about?(user, event)
      return false if open_question_about?(user, link, event)

      chore = find_chore(user, link.target_name)
      return false if chore.nil?

      # `scope` is what the question is later compared on: which of the links
      # into this chore the doing arrived through. Kept on the prompt rather
      # than re-derived, because the event behind it can be deleted.
      prompt = ::ChoreWhoDidIt.ask!(
        user,
        chore,
        at:          parse_time(event.timestamp) || Time.current,
        stand_in_on: chore.completion_leaf_for(user),
        extra:       { event_id: event.id, scope: link.source_scope },
      )
      prompt.present?
    rescue StandardError => e
      Rails.logger.warn("[RecordLinks] ask_who #{link.target_name.inspect}: #{e.class}: #{e.message}")
      false
    end

    def asked_about?(user, event)
      user.prompts.unanswered.exists?(["params->>'event_id' = ?", event.id.to_s])
    end

    # How long one open "who did it" covers the next event for the same chore.
    # Long enough for a mis-press and its correction, short enough that a
    # question left unanswered on Monday isn't still swallowing Tuesday's.
    SAME_QUESTION_WINDOW = 15.minutes

    # The guard above is keyed on the EVENT, so two events ask twice - which is
    # right when they're two separate doings and wrong when they're one.
    #
    # Two device events seconds apart put up two identical attribution forms.
    # One press corrected by a hold is the intended way to fix a mistake - and
    # the device sends the same nameless event either way, so nothing
    # downstream can tell the correction from a second bedtime. He skipped one
    # form and answered the other.
    #
    # Answering EITHER writes the same completion, so a second open copy adds
    # nothing whichever way it got there.
    #
    # ONLY A RECLASSIFICATION IS DEBOUNCED: the same doing arriving again
    # through a DIFFERENT link. Whisper reaches `Puppy Down` by three of them -
    # `Nap`, `Sleep` and `Down`, record_links 21-23 - so a press for a nap
    # corrected by a hold for sleep is one bedtime described twice, and that is
    # the whole case this exists for. Two NAPS are two doings and each has to be
    # asked about however close together they land; there can easily be more
    # than one in an afternoon. Keying on the chore alone made those
    # indistinguishable and swallowed the second one, which is why the scope is
    # compared and not just the name.
    #
    # The window is measured between the two EVENTS, and the first cut of this
    # measured `prompts.created_at` instead - which is the same number only
    # while events reach the database as fast as they happen: two events fifty
    # seconds apart can arrive twenty minutes apart, so a guard measured on
    # prompt time lets the duplicate through.
    #
    # An open prompt whose event has since been deleted falls back to its
    # `created_at` for the timing - the deletion is real, 51934 no longer
    # exists. A prompt with no scope recorded at all predates this and is left
    # alone: asking twice is the recoverable mistake, and staying silent about a
    # real second doing is not.
    def open_question_about?(user, link, event)
      open = user.prompts.unanswered.where(
        ["params->>'source' = ? AND params->>'chore_name' = ?", "ambiguous_chore", link.target_name.to_s],
      ).to_a
      return false if open.empty?

      facts = event_facts(open)
      open.any? { |prompt|
        params = prompt.params.to_h.with_indifferent_access
        fact   = facts[params[:event_id].to_s] || {}
        scope  = params[:scope].presence || fact[:notes]
        next false if scope.blank? || scope.to_s.casecmp?(link.source_scope.to_s)

        at = fact[:timestamp] || prompt.created_at
        (event.timestamp - at).abs <= SAME_QUESTION_WINDOW
      }
    end

    # One query for the lot rather than a lookup per open prompt. `notes` comes
    # back too so a prompt written before `scope` was stored can still say which
    # link it came through.
    def event_facts(prompts)
      ids = prompts.filter_map { |p| p.params.to_h.with_indifferent_access[:event_id].presence }
      return {} if ids.empty?

      ActionEvent.where(id: ids).pluck(:id, :timestamp, :notes).to_h { |id, at, notes|
        [id.to_s, { timestamp: at, notes: notes }]
      }
    end

    def on_prompt(user, prompt, attrs)
      return unless (attrs[:status] || attrs["status"]).to_s == "complete"
      return unless ::ChoreWhoDidIt.ours?(prompt)

      # Guarded on the PROMPT, not on the chore it's about. Guarding the chore
      # here looked right and was exactly wrong: it claimed that endpoint before
      # the completion existed, so the completion's own cascade — tick off the
      # agenda task, take the item off the list — found it already visited and
      # did nothing. The chore rung guards itself in `on_completion`.
      # The event keeps its row and takes the answered time (ChoreWhoDidIt
      # moves it). One link per pairing means there's no earlier completion of
      # it to undo.
      Guard.visiting([:prompt, prompt.try(:id)]) { ::ChoreWhoDidIt.answer!(user, prompt) }
    end

    # ---- shared ----

    # `:item` payloads come off the bus as plain hashes and reach here through
    # `overlay`, which symbolizes only the top level — a nested `list` still
    # carries string keys.
    def fetch(hash, key)
      hash[key] || hash[key.to_s]
    end

    def find_chore(user, name)
      user.accessible_chores.active.detect { |c| c.name.to_s.casecmp(name.to_s).zero? }
    end

    def parse_time(value)
      return nil if value.blank?
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def dig_change(changes, key)
      pair = changes.is_a?(Hash) ? (changes[key] || changes[key.to_sym]) : nil
      Array(pair).first
    end
  end
end
