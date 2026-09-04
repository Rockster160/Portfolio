# == Schema Information
#
# Table name: record_links
#
#  id                 :bigint           not null, primary key
#  user_id            :bigint           not null
#  source_kind        :integer          not null
#  source_name        :text             not null
#  source_scope       :text
#  source_name_match  :integer          default("exactly"), not null
#  source_scope_match :integer          default("exactly"), not null
#  target_kind        :integer          not null
#  target_name        :text             not null
#  target_scope       :text
#  ask_who            :boolean          default(FALSE), not null
#  reverse            :boolean          default(FALSE), not null
#  enabled            :boolean          default(TRUE), not null
#  note               :text
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
class RecordLink < ApplicationRecord
  belongs_to :user

  # The cascade, in order. A link's source must outrank its target — that one
  # rule is what keeps this comprehensible, and it's enforced below rather than
  # left to whoever writes the row.
  #
  #     event  ->  chore  ->  agenda  ->  list_item
  #
  # Logging an event completes the chore; completing the chore ticks off the
  # agenda item and the list item. Nothing runs back up: completing a chore does
  # NOT write an event, and checking something off a list does NOT touch the
  # chore. Those two used to happen and were the only way the old rules could
  # chase each other in a circle.
  KINDS = { event: 0, chore: 1, agenda: 2, list_item: 3 }.freeze
  RANK  = KINDS

  # Everything with something below it. A list item is the bottom of the
  # cascade, so a link sourced from one could never have a valid target — the
  # manager doesn't offer it rather than offering it and refusing every choice.
  SOURCE_KINDS = KINDS.keys[0..-2].freeze

  enum :source_kind, KINDS, prefix: :source
  enum :target_kind, KINDS, prefix: :target

  # How the source side is matched against what actually fired. Exact is right
  # for a chore, whose name is a record. It's wrong for anything free-typed —
  # a medication logged with its dosage, a note somebody spells two ways.
  MATCHES = { exactly: 0, starts_with: 1, contains: 2 }.freeze

  enum :source_name_match,  MATCHES, prefix: :name_match
  enum :source_scope_match, MATCHES, prefix: :scope_match

  MATCH_LABELS = {
    "exactly"     => "is exactly",
    "starts_with" => "starts with",
    "contains"    => "contains",
  }.freeze

  KIND_LABELS = {
    "event"     => "logged event",
    "chore"     => "chore",
    "agenda"    => "agenda task",
    "list_item" => "list item",
  }.freeze

  KIND_ICONS = {
    "event"     => "📋",
    "chore"     => "🧹",
    "agenda"    => "📅",
    "list_item" => "📝",
  }.freeze

  validates :source_name, :target_name, presence: true
  validate :cascade_runs_downhill
  validate :scope_belongs_on_this_kind

  scope :live, -> { where(enabled: true) }

  # Links whose source is this kind, for a scope that just fired. The name match
  # can't be done in SQL (three modes, case-insensitive, per row), so this
  # narrows by kind and the propagator filters the rest in Ruby. There are tens
  # of these rows, not thousands.
  scope :sourced_from, ->(user, kind) {
    live.where(user_id: user.id, source_kind: KINDS.fetch(kind.to_sym))
  }

  # The uphill escape hatch, read from the other end.
  #
  # `reverse` ADDS the backwards reading to a pairing; it does not replace the
  # forwards one, and `sourced_from` deliberately does not filter it out. The
  # uniqueness index is what decides that: it covers the two endpoints and
  # pointedly NOT this column, so one pairing is one row and "both directions"
  # could never have been two of them. A chore that both puts its item on the
  # list and comes due when the item goes back on is one row with this set.
  #
  # The match modes belong to the row rather than to a direction, so an uphill
  # reading matches the list item with whatever `source_name_match` says. Fine
  # while both ends are `exactly`, which is every pairing that wants this so
  # far; a pairing needing different strictness each way needs its own column
  # before it needs a second row.
  scope :reversed_from, ->(user, kind) {
    live.where(user_id: user.id, target_kind: KINDS.fetch(kind.to_sym), reverse: true)
  }

  # Does this link's source match the thing that fired? `name` and `scope` are
  # whatever the record actually carries.
  def matches?(name, scope=nil)
    return false unless compare(source_name, name, source_name_match)
    # A blank scope on the link means "don't care", which is what separates a
    # link on all Fae events from one on Fae/Litter specifically.
    return true if source_scope.blank?

    compare(source_scope, scope, source_scope_match)
  end

  def summary
    arrow = reverse? ? "↔" : "→"
    "#{endpoint(source_kind, source_name, source_scope)} #{arrow} #{endpoint(target_kind, target_name, target_scope)}"
  end

  # What it does, in a sentence, for the manager and for receipts. A reverse row
  # does two things and has to say both — the manager page is the only place a
  # row explains itself, and half an explanation there is how a link ends up
  # doing something nobody remembers asking for.
  def sentence
    [downhill_sentence, (uphill_sentence if reverse?)].compact.join(", and back: ")
  end

  def downhill_sentence
    verb = (
      case target_kind
      when "chore"     then ask_who? ? "asks who did" : "completes"
      when "agenda"    then "ticks off today's"
      when "list_item" then "takes off the list"
      else                  "updates"
      end
    )
    "#{source_phrase} #{verb} #{KIND_LABELS[target_kind]} #{target_name.inspect}" \
      "#{" on #{target_scope}" if target_scope.present?}"
  end

  # Uphill only ever lands on a chore, and it does NOT complete one — it marks
  # it due. Different claim, so it reads as a different verb.
  def uphill_sentence
    "#{source_phrase(target_kind, target_name, target_scope)} marks due " \
      "#{KIND_LABELS[source_kind]} #{source_name.inspect}"
  end

  # `scope` is a note on an event and a LIST on a list item, so it can't be
  # called the same thing in both readings.
  def source_phrase(kind=source_kind, name=source_name, scope=source_scope)
    bits = ["#{KIND_LABELS[kind]} where name #{MATCH_LABELS[source_name_match]} #{name.inspect}"]
    noun = kind == "list_item" ? "list" : "notes"
    bits << "#{noun} #{MATCH_LABELS[source_scope_match]} #{scope.inspect}" if scope.present?
    bits.join(" and ")
  end

  # Whether both ends point at something that exists. A link naming a chore
  # nobody has is not an error anywhere — it simply never fires — so the manager
  # asks this and says so out loud.
  def broken_ends
    out = []
    out << "no chore called #{chore_end.inspect}" if chore_end && !chore_exists?
    out << "no list called #{list_scope.inspect}" if list_scope && !list_exists?
    out
  end

  def chore_end
    return source_name if source_chore?
    return target_name if target_chore?

    nil
  end

  def list_scope
    return source_scope if source_list_item?
    return target_scope if target_list_item?

    nil
  end

  private

  def chore_exists?
    user.accessible_chores.active.any? { |c| c.name.to_s.casecmp(chore_end.to_s).zero? }
  rescue StandardError
    true
  end

  def list_exists?
    ::List.by_name_for_user(list_scope, user).present?
  rescue StandardError
    true
  end

  def compare(pattern, value, mode)
    a = pattern.to_s.downcase.strip
    b = value.to_s.downcase.strip
    return false if a.empty?

    case mode.to_s
    when "starts_with" then b.start_with?(a)
    when "contains"    then b.include?(a)
    else                    b == a
    end
  end

  def endpoint(kind, name, scope)
    scope.present? ? "#{kind}:#{name} (#{scope})" : "#{kind}:#{name}"
  end

  def cascade_runs_downhill
    return if source_kind.blank? || target_kind.blank?
    return if RANK.fetch(source_kind.to_sym, 99) < RANK.fetch(target_kind.to_sym, 99)

    errors.add(
      :target_kind,
      "must come after #{source_kind} in the cascade (#{KINDS.keys.join(" -> ")})",
    )
  end

  # A scope means a different thing per kind and nothing at all on most of them:
  # an event's notes, a list item's list, and on an agenda target the single
  # word "overdue" (which widens the sweep past today, reproducing Jil task
  # 370). Silently ignoring one somebody set is how a link ends up not doing
  # what the row plainly says it does.
  AGENDA_SCOPES = %w[overdue].freeze

  def scope_belongs_on_this_kind
    errors.add(:source_scope, "only means something on an event (its notes)") if source_scope.present? && !source_event?
    return if target_scope.blank?
    return if target_list_item?
    return if target_agenda? && AGENDA_SCOPES.include?(target_scope.to_s.downcase)

    errors.add(:target_scope, "only means something on a list item (which list) or an agenda task (\"overdue\")")
  end
end
