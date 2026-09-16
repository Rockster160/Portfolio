# Keeps the "Chores" list and the Chores app saying the same thing.
#
#   chore due today or overdue  ->  an item on the list
#   an item typed onto the list ->  a chore due that day
#   the item ticked off         ->  the chore completed
#
# This is a BLANKET mirror of a whole set, which is what separates it from
# `RecordLinks` next door. A RecordLink is one hand-made pairing between one
# named chore and one named item, and the four that used to point at this list
# were retired when this arrived — a per-chore rule for a set that syncs
# wholesale is a second source of truth and a duplicate row on the list.
#
# The set is deliberately narrower than the Today tab: due today, plus overdue
# carryover, and nothing else. A Dailies pin or a `show_on_today_view: always`
# chore sits on Today without being DUE, and putting those here would make the
# list a copy of a screen rather than a list of what needs doing. A chore that
# has been done or skipped today drops out the same day.
#
# Rocco, 2026-09-14: "most recently due chores appear at the top" — so the sort
# is due-date DESCENDING. Today's work is at the top and the thing that has been
# sitting there for three weeks is at the bottom.
class ChoreListSync
  LIST_NAME = "Chores".freeze

  # The two sections the list is drawn in, top first. A chore is in exactly one
  # of them: due on this chore-day, or due on an earlier one and still not done.
  SECTIONS = [
    { key: :today,   name: "Today",   color: "#0160ff" },
    { key: :overdue, name: "Overdue", color: "#df0d15" },
  ].freeze

  # Set while this class is doing its own writing. Every write it makes fires
  # the same `:item` triggers a person's tap does, so each one arrives back at
  # `dispatch` asking to be interpreted.
  #
  # Not what stops that being acted on — the due-set checks in `item_added` and
  # `item_removed` already do, and they are complementary to what `push`
  # writes by construction: push only adds what IS due and only removes what is
  # NOT, and those two branches only act on the opposite. Pull this flag and the
  # behaviour is unchanged.
  #
  # What it stops is the COST. Every one of those trips builds a whole fresh
  # ChoreSerializerContext — every chore, completion and streak bulk-loaded —
  # to answer one "is this due?" and then throws it away. Measured on twelve due
  # chores: 1 context and 335 queries with this, 13 and 779 without.
  #
  # Thread-local rather than class-level because Sidekiq runs several jobs per
  # process, and one worker's reconcile must not suppress another worker's real
  # tick. Same mechanism and the same reason as `RecordLinks::Guard`.
  WRITING_KEY = :chore_list_sync_writing

  class << self
    # Reconcile now, inline. Callers that are on a request thread should use
    # `enqueue` instead — this walks every chore the user can see.
    def push(user)
      new(user).push
    end

    def enqueue(user_or_id)
      return if writing?

      id = user_or_id.is_a?(::User) ? user_or_id.id : user_or_id
      return if id.blank?

      ChoreListSyncWorker.perform_async(id)
    end

    # Every user in `household_id` who actually keeps one of these lists. A
    # chore is household-wide; the list is one person's, so a change has to
    # fan out to whoever is mirroring it rather than to whoever happened to
    # touch the record.
    def subscribers(household_id)
      return ::User.none if household_id.blank?

      ::User.joins(user_lists: :list)
        .where(user_lists: { is_owner: true })
        .where(lists: { parameterized_name: LIST_NAME.parameterize })
        .where(chore_household_id: household_id)
        .distinct
    end

    def enqueue_for_household(household_id)
      subscribers(household_id).each { |user| enqueue(user) }
    end

    # Everyone keeping one of these lists, whatever household they are in. The
    # 4am rollover has no chore in hand to scope by.
    def subscribers_everywhere
      ::User.joins(user_lists: :list)
        .where(user_lists: { is_owner: true })
        .where(lists: { parameterized_name: LIST_NAME.parameterize })
        .where.not(chore_household_id: nil)
        .distinct
    end

    # The uphill half, off the same bus `RecordLinks::Propagator` rides — the
    # list UI ticks over a socket, Buddy and Jil go through the model, and both
    # controllers fire their own trigger, so the bus is the only place that
    # sees all four.
    def dispatch(user, scope, payload)
      return unless scope.to_s == "item"
      return if writing? || user.nil? || payload.nil?

      attrs = payload.is_a?(::Hash) ? payload : {}
      action = fetch(attrs, :action).to_s
      return unless [:added, :removed].include?(action.to_sym)

      new(user).on_item(fetch(attrs, :name).to_s, action.to_sym, list_id: item_list_id(attrs))
    rescue StandardError => e
      # A mirror is a convenience. It must never take down the tap, the
      # request, or the automation that fired the trigger.
      ::Rails.logger.error("[ChoreListSync] dispatch failed: #{e.class}: #{e.message}")
      nil
    end

    def writing?
      ::Thread.current[WRITING_KEY].present?
    end

    def writing
      return yield if writing?

      ::Thread.current[WRITING_KEY] = true
      begin
        yield
      ensure
        ::Thread.current[WRITING_KEY] = nil
      end
    end

    def item_list_id(attrs)
      list = fetch(attrs, :list)
      list.is_a?(::Hash) ? fetch(list, :id) : nil
    end

    # `:item` payloads reach the bus as plain hashes whose nesting keeps string
    # keys — same shape `RecordLinks::Propagator#fetch` reads.
    def fetch(hash, key)
      hash[key] || hash[key.to_s]
    end
  end

  attr_reader :user, :day

  def initialize(user, day: nil)
    @user = user
    @day = day || ::ChoreDay.current(user)
  end

  def list
    return @list if defined?(@list)

    @list = user.ordered_lists.find_by(parameterized_name: LIST_NAME.parameterize)
  end

  # ONE sync per person at a time. Marking a chore due enqueues two of these —
  # `item_added` asks for one, and the `marked_due_at` write fires Chore's own
  # `after_commit` which asks for another — and Sidekiq runs them side by side.
  # Both read the list before either writes, so both decide the same item is
  # missing and both add it. `writing` is thread-local and cannot see across
  # Sidekiq threads, let alone processes, so it was never going to stop this.
  #
  # 16 Sep: "Unpack Dishes" typed onto the list matched chore 78 by its alias,
  # and the two syncs added "Unload Dishwasher" 0.8ms apart. One of the pair was
  # placed under Today; the other kept `max_sort_order + 1` and no section,
  # which sorts ABOVE the Today header — a second copy of the chore pinned to
  # the top of the list, in no section at all.
  #
  # Waits rather than skips: the second run may have been asked for by a change
  # the first one started too early to see, and a reconcile that runs twice
  # costs a redraw, while one that never runs leaves the list wrong.
  def push
    return nil if list.nil?

    User.with_advisory_lock("chore_list_sync_#{user.id}", 15.seconds) { reconcile! }
    list
  end

  # Make the list say exactly what the due set says, in due order.
  #
  # Items that match no chore at all are left where they are. They are somebody
  # typing a note to themselves, and the uphill half turns anything that was
  # meant as a chore into one within the same breath anyway.
  def reconcile!
    self.class.writing {
      due = due_rows
      wanted = due.index_by { |row| key(row[:name]) }
      present = collapse_duplicates(list.list_items.to_a.group_by { |item| key(item.name) })

      (wanted.keys - present.keys).each { |k| list.list_items.add(wanted[k][:name]) }
      present.each { |k, item| list.list_items.remove(item.name) if !wanted.key?(k) && known_chore?(k) }

      restamp!(due)
    }
    list.broadcast!
  end

  # The list is a mirror, so two rows saying the same thing is never something a
  # person meant — it is a race that already happened. Collapse them here rather
  # than leaving `restamp!` to pick one and strand the other, and the stray from
  # any earlier race is cleared by the next sync instead of needing a script.
  # The oldest row is the keeper; `restamp!` renumbers it into place regardless.
  def collapse_duplicates(grouped)
    grouped.transform_values { |items|
      keep, *extra = items.sort_by(&:id)
      extra.each { |dupe| dupe.update(deleted_at: ::Time.current, do_not_broadcast: true) }
      keep
    }
  end

  # One item, one direction: onto the list means the chore is due, off the list
  # means it is done.
  def on_item(name, action, list_id: nil)
    return nil if list.nil? || name.blank?
    return nil if list_id.present? && list_id.to_i != list.id

    case action
    when :added   then item_added(name)
    when :removed then item_removed(name)
    end
  end

  private

  # A person put it on the list. If it names a chore, that chore is due now; if
  # it names nothing, it is a new one-off due today. Either way the reconcile
  # that follows is what actually places and orders the item.
  def item_added(name)
    chore = find_chore(name)

    if chore.nil?
      chore = create_chore!(name)
    else
      return nil if due_ids.include?(chore.id) # the mirror put it there

      chore.update!(marked_due_at: ::Time.current) unless chore.marked_due?
    end

    self.class.enqueue(user)
    chore
  end

  # A tick is a completion — the same one the card's tap writes, through the
  # same service, so pebbles, streak, cooldown and the Jil triggers all behave
  # as if they had tapped it. Anything the mirror did not put there is left
  # alone: ticking a note to yourself must not go looking for a chore to finish.
  def item_removed(name)
    chore = find_chore(name)
    return nil if chore.nil? || due_ids.exclude?(chore.id)

    result = ::ChoreCompleter.new(chore.completion_leaf_for(user), user).call
    self.class.enqueue(user)
    result
  end

  def create_chore!(name)
    ::Chore.create!(
      name:               name,
      created_by_user:    user,
      chore_household_id: user.chore_household_id,
      one_off:            true,
      starts_on:          day,
      reward_pebbles:     1, # what the Add Chore form offers for a new one
    )
  end

  # Due today, or due on some earlier day and still not done.
  #
  # `scheduled_due_on` is the serializer's own answer to "what day was this
  # for", so an overdue chore is one whose day has passed — which also filters
  # out the always-on chores that sit on Today with no due day at all.
  def due_rows
    @due_rows ||= (
      ctx = ::ChoreSerializerContext.for_user(user, day: day)
      rows = ctx.serialize_all(user.accessible_chores.to_a).select { |row| due_or_overdue?(row) }
      rows.sort_by { |row| [-due_on(row).to_time.to_i, -row[:priority_rank].to_i, row[:name].to_s.downcase] }
    )
  end

  def due_ids
    @due_ids ||= due_rows.to_set { |row| row[:id] }
  end

  def due_or_overdue?(row)
    return false if row[:archived] || row[:skipped_today]
    return false if row[:done_count_today].to_i >= row[:target_count].to_i
    # Dailies are out, by the pin OR by the recurrence, and being genuinely due
    # today buys neither of them back in. A `freq: daily` chore is due every
    # single day, so reading dueness first put the whole standing routine at the
    # top of the list — the one thing this was asked not to carry. The pin and
    # the recurrence each answer on their own.
    return false if row[:on_dailies] || daily?(row)
    return true  if row[:due_today]
    return false unless row[:today_visible] && row[:scheduled_due_on].present?

    ::Date.parse(row[:scheduled_due_on]) < day
  end

  def due_on(row)
    row[:scheduled_due_on].present? ? ::Date.parse(row[:scheduled_due_on]) : day
  end

  # `recurrence` rides the payload as the chore's raw jsonb, so its keys are
  # strings however the rest of the row reads.
  def daily?(row)
    rec = row[:recurrence]
    return false unless rec.is_a?(::Hash)

    (rec[:freq] || rec["freq"]).to_s == "daily"
  end

  def section_key(row)
    row[:due_today] ? :today : :overdue
  end

  # Renumbered whole rather than pushed above the previous maximum: a mirror
  # that runs every time a chore moves would otherwise walk `sort_order` up by
  # the size of the list forever. Items the mirror doesn't own keep their order
  # relative to each other and settle underneath.
  # Lay the whole list out in one pass: Today's section and its items, then
  # Overdue's and its items, then anything the mirror doesn't own.
  #
  # Renumbered whole rather than pushed above the previous maximum — a mirror
  # that runs every time a chore moves would otherwise walk `sort_order` up by
  # the size of the list forever. Sections and items share the one sequence
  # because `List#sectioned_objects` merges them into a single descending sort
  # before it groups; a section only has to outrank the items underneath it.
  # GROUPED by name, never indexed. Two rows can share one, and `index_by` kept
  # the last and silently dropped the rest — a dropped row is never placed, so
  # it keeps the `max_sort_order + 1` it was created with and sorts above every
  # section header. Every row this walks gets a sort_order and a section, even
  # the ones it would rather not have.
  def restamp!(due)
    by_key = list.list_items.ordered.to_a.group_by { |item| key(item.name) }
    by_section = due.group_by { |row| section_key(row) }

    # [record, section it belongs under] in final top-to-bottom order.
    placed = SECTIONS.flat_map { |spec|
      rows = by_section[spec[:key]].to_a
      section = section_row(spec, create: rows.any?)
      next [] if section.nil?

      items = rows.flat_map { |row| by_key[key(row[:name])].to_a }
      [[section, nil]] + items.map { |item| [item, section] }
    }
    # Items matching no chore keep their order relative to each other and settle
    # underneath both sections, in neither of them.
    seen = placed.to_set { |record, _| record }
    placed += (by_key.values.flatten - seen.to_a).map { |item| [item, nil] }

    total = placed.size
    placed.each_with_index { |(record, section), idx|
      attrs = { sort_order: total - idx }
      attrs[:section_id] = section&.id if record.is_a?(::ListItem)
      next if attrs.all? { |field, value| record.public_send(field) == value }

      record.update(attrs.merge(do_not_broadcast: true))
    }
  end

  # Created on first use rather than seeded, so a list that has never had an
  # overdue chore never grows a header saying it might.
  #
  # Once created it STAYS, empty or not: a section that came and went as the
  # last overdue chore was ticked would take its id with it, and every item
  # under it would have to be re-pointed at a new row the next morning. An empty
  # "Overdue" band is also the clearest way to say there is nothing overdue.
  def section_row(spec, create:)
    existing = list.sections.where_soft_name(spec[:name]).first
    return existing if existing
    return nil unless create

    list.sections.create!(name: spec[:name], color: spec[:color], do_not_broadcast: true)
  end

  def find_chore(name)
    k = key(name)
    active_chores.find { |c| key(c.name) == k || c.aliases_array.any? { |a| key(a) == k } }
  end

  # Archived chores count as known so a finished one-off's item is cleared off
  # the list rather than sitting there matching nothing forever.
  def known_chore?(k)
    household_chore_keys.include?(k)
  end

  def active_chores
    @active_chores ||= user.accessible_chores.to_a
  end

  # Names AND aliases, because `find_chore` matches on both and the two have to
  # agree about what counts as naming a chore. They didn't: "Unpack Dishes" is
  # an alias of chore 78, so the uphill half resolved it and marked the chore
  # due, then this half read it as a note to itself and left it on the list
  # forever underneath the "Unload Dishwasher" row the mirror had just added.
  # What should look like one item being corrected to its real name was two
  # items, and only the new one meant anything.
  def household_chore_keys
    @household_chore_keys ||= ::Chore.where(chore_household_id: user.chore_household_id)
      .pluck(:name, :aliases).flatten.compact_blank.to_set { |name| key(name) }
  end

  def key(name)
    ::ListItem.format_name(name)
  end
end
