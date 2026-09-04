module RecordLinks
  # Carries a completion downhill.
  #
  #     event  ->  chore  ->  agenda  ->  list_item
  #
  # This is the Rails half of what Jil tasks 362, 365, 366, 370, 374, 382, 383
  # and 416 used to do. Both of the old uphill rules were dropped when this
  # replaced them: completing a chore no longer writes an ActionEvent, and
  # adding a list item no longer marked a chore due. The cron and button tasks
  # that relied on the second one were converted to mark the chore due
  # themselves, which pushes the item back down the cascade and arrives in the
  # same place with the arrow pointing one way.
  #
  # What that conversion missed was the SPOKEN path. "Add Pickup RX to Chores"
  # is a sentence a person says, not a task anybody could rewrite, and for a
  # chore that is unscheduled and `when_scheduled` the mark is the only thing
  # that can put it on Today — so it went on the list, stayed off the Chores
  # app, and reported no error anywhere, because `item` was in SCOPES with no
  # branch to land in. `on_item` is that branch. It runs for a pairing
  # explicitly marked `reverse` and for nothing else, so the cascade is still
  # one-way everywhere it was not deliberately opened.
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
      return ask_who(user, link, event) if action == :added && matched && link.ask_who?
      return nil if link.ask_who?

      chore = find_chore(user, link.target_name)
      return nil if chore.nil?

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
      name = completion&.chore&.name
      return if name.blank?

      each_link(user, :chore, [name]) { |link|
        next unless link.matches?(name)

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

    def completion_partner(user, chore, at)
      return nil if chore.nil? || at.blank?

      user.chore_completions
        .where(chore_id: chore.id, completed_at: (at - WINDOW)..(at + WINDOW))
        .order(:completed_at).first
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

    WHO_QUESTION  = "Who did it?".freeze
    WHEN_QUESTION = "When?".freeze

    # Several chores share one event and only a person can say which. The event
    # is left exactly as logged; nothing completes until the answer comes back.
    def ask_who(user, link, event)
      names = household_names(user)
      return false if names.empty?
      # The bus can deliver `added` twice for one row (a retried job, a fan-out),
      # and a second identical prompt is a second thing to dismiss.
      return false if asked_about?(user, event)
      return false if open_question_about?(user, link, event)

      prompt = user.prompts.create!(
        question: "Who did: #{link.target_name}?",
        # `scope` is what the question is later compared on: which of the links
        # into this chore the doing arrived through. Kept on the prompt rather
        # than re-derived, because the event behind it can be deleted.
        params:   { source: "ambiguous_chore", chore_name: link.target_name, event_id: event.id, scope: link.source_scope },
        options:  [
          { type: :select, question: WHO_QUESTION, choices: names, default: "" },
          { type: :datetime, question: WHEN_QUESTION, default: local_datetime(user, event.timestamp) },
        ],
      )
      ::Jil.trigger(user, :prompt, prompt.with_jil_attrs(state: :create), auth: :link)
      # Also ask it where they already are. The whole question is one dropdown
      # over a timestamp that's already correct, and routing that through a
      # notification into /prompts costs four steps to collect one word.
      ::Buddy::PromptDelivery.post!(user, prompt)
      true
    rescue StandardError => e
      Rails.logger.warn("[RecordLinks] ask_who #{link.target_name.inspect}: #{e.class}: #{e.message}")
      false
    end

    # The field this lands in is `<input type="datetime-local">`, which accepts a
    # local date and time and NOTHING else. `iso8601` ends in an offset, which
    # makes the value invalid, and an invalid value renders as an EMPTY box —
    # no error, just a question with the answer rubbed off it. Task 365 wrote
    # minutes-precision local time and that is what has to come back.
    def local_datetime(user, time)
      return nil if time.blank?

      time.in_time_zone(user.timezone).strftime("%Y-%m-%dT%H:%M")
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
    # Prod, 26 Aug 22:00: two Whisper events nineteen seconds apart, 51790 and
    # 51791, put up two identical `Who did: Puppy Down?` forms. It was one press
    # for a nap corrected by a hold for sleep, which is the intended way to fix
    # it - and the device sends the same nameless event either way, so nothing
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
    # while events reach the database as fast as they happen. Prod, 31 Aug
    # 22:00: events 51933 and 51934 were fifty seconds apart, but 51934 did not
    # arrive until 22:21:52, so the two prompts were 21m42s apart and a
    # 15-minute guard on prompt time let the duplicate through.
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

      params = (prompt.try(:params) || {}).to_h.with_indifferent_access
      return unless params[:source].to_s == "ambiguous_chore"

      response = (prompt.try(:response) || {}).to_h.with_indifferent_access
      # Guarded on the PROMPT, not on the chore it's about. Guarding the chore
      # here looked right and was exactly wrong: it claimed that endpoint before
      # the completion existed, so the completion's own cascade — tick off the
      # agenda task, take the item off the list — found it already visited and
      # did nothing. The chore rung guards itself in `on_completion`.
      Guard.visiting([:prompt, prompt.try(:id)]) {
        answered(
          user,
          chore_name: params[:chore_name],
          event_id:   params[:event_id],
          completer:  response[WHO_QUESTION],
          at:         parse_time(response[WHEN_QUESTION]),
        )
      }
    end

    def answered(user, chore_name:, event_id:, completer:, at:)
      chore = find_chore(user, chore_name)
      return false if chore.nil?

      who = ::User.find_by(username: completer) || user
      # For WHO did it, not for whose links these are - the whole point of the
      # question is that it wasn't necessarily the person who logged it.
      complete_once(chore.completion_leaf_for(who), who, at || Time.current)
      # The event keeps its row and takes the answered time. Under Jil this
      # branch sometimes DESTROYED it, to undo a completion task 362 had already
      # made from the same log. One link per pairing means there's nothing to
      # undo.
      event = user.action_events.find_by(id: event_id)
      event&.update!(timestamp: at) if at.present?
      true
    end

    # The one completion write with no partner to find first, so it has to look
    # for itself. An answer reaches the bus more than once often enough to
    # matter — a retried job, the app and Buddy both submitting the same form —
    # and a second ChoreCompleter call is a second row in the history and a
    # second payout for one puppy. A re-answer that names someone ELSE is left
    # alone rather than moved: the payout was already computed for whoever is
    # on the row, and reassigning credit is what editing the completion is for.
    def complete_once(chore, who, at)
      return false if completed_in_window?(chore, at)

      ::ChoreCompleter.new(chore, who, at: at).call
      true
    end

    # Not `user.chore_completions` like `completion_partner` — the person named
    # in the answer is usually NOT the person whose links these are, so a
    # user-scoped lookup never sees the row it just made.
    def completed_in_window?(chore, at)
      ::ChoreCompletion.exists?(
        chore_id:     chore.id,
        completed_at: (at - WINDOW)..(at + WINDOW),
      )
    end

    def household_names(user)
      ids = Array(user.chore_household&.member_user_ids)
      return [] if ids.empty?

      ::User.where(id: ids).order(:id).pluck(:username).compact_blank
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
