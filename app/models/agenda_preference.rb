# == Schema Information
#
# Table name: agenda_preferences
#
#  id                   :bigint           not null, primary key
#  hidden_agenda_ids    :jsonb            not null
#  hidden_item_ids      :jsonb            not null
#  hidden_name_patterns :jsonb            not null
#  hidden_schedule_ids  :jsonb            not null
#  hide_completed       :jsonb            not null
#  hide_tentative       :boolean          default(FALSE), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  user_id              :bigint           not null
#
class AgendaPreference < ApplicationRecord
  KIND_KEYS = %w[task event trigger].freeze

  belongs_to :user

  validates :user_id, uniqueness: true
  validate :validate_pattern_compiles

  def self.for(user)
    find_or_initialize_by(user: user).tap { |pref|
      pref.hide_completed       ||= {}
      pref.hidden_agenda_ids    ||= []
      pref.hidden_schedule_ids  ||= []
      pref.hidden_item_ids      ||= []
      pref.hidden_name_patterns ||= []
    }
  end

  def hidden_agenda_ids=(value)
    super(Array(value).map(&:to_i).uniq)
  end

  def hidden_schedule_ids=(value)
    super(Array(value).map(&:to_i).uniq)
  end

  def hidden_item_ids=(value)
    super(Array(value).map(&:to_i).reject(&:zero?).uniq)
  end

  def hidden_name_patterns=(value)
    cleaned = Array(value).map { |s| s.to_s.strip }.reject(&:empty?).uniq
    super(cleaned)
  end

  def hide_completed_for?(kind)
    !!hide_completed[kind.to_s]
  end

  def hide_completed=(value)
    cleaned = (value || {}).to_h.slice(*KIND_KEYS).transform_values { |v| !!v }
    super(cleaned)
  end

  # SQL-level filter excluding rows matching ANY hide criterion. Used by
  # Jil's `is:visible` token so the DB does the filtering — keeps LIMIT
  # accurate and avoids loading then-discarded rows into Ruby. Phantom
  # items (built in memory after SQL) still go through #item_hidden?.
  def apply_visible_scope(scope)
    scope = scope.where.not(agenda_id: hidden_agenda_ids) if hidden_agenda_ids.any?
    # `where.not(col: [...])` excludes NULL too in Rails (SQL `NOT IN`
    # treats NULL as unknown). Non-recurring items have a NULL schedule
    # id; spell out the predicate so they survive the filter.
    if hidden_schedule_ids.any?
      scope = scope.where(
        "agenda_items.agenda_schedule_id IS NULL OR agenda_items.agenda_schedule_id NOT IN (?)",
        hidden_schedule_ids,
      )
    end
    scope = scope.where.not(id: hidden_item_ids) if hidden_item_ids.any?
    hidden_name_patterns.each { |p| scope = scope.where("agenda_items.name !~* ?", p) }
    scope
  end

  # Inverse of #apply_visible_scope — returns only rows matching ANY
  # hide criterion. Used by the `is:hidden` token.
  def apply_hidden_scope(scope)
    conds = []
    binds = []
    if hidden_agenda_ids.any?
      conds << "agenda_items.agenda_id IN (?)"
      binds << hidden_agenda_ids
    end
    if hidden_schedule_ids.any?
      conds << "agenda_items.agenda_schedule_id IN (?)"
      binds << hidden_schedule_ids
    end
    if hidden_item_ids.any?
      conds << "agenda_items.id IN (?)"
      binds << hidden_item_ids
    end
    hidden_name_patterns.each do |p|
      conds << "agenda_items.name ~* ?"
      binds << p
    end
    return scope.none if conds.empty?
    scope.where(conds.join(" OR "), *binds)
  end

  # True when the given AgendaItem matches ANY of the user's hide lists:
  # its agenda, its schedule, its own id, or any of the name regex
  # patterns. Used for phantoms (built in memory, so SQL scoping can't
  # see them) and for direct predicate checks.
  def item_hidden?(item)
    return false if item.nil?
    return true if hidden_agenda_ids.include?(item.agenda_id)
    return true if item.agenda_schedule_id && hidden_schedule_ids.include?(item.agenda_schedule_id)
    return true if item.id && hidden_item_ids.include?(item.id)
    name = item.name.to_s
    matched = hidden_name_patterns.any? do |src|
      Regexp.new(src.to_s, Regexp::IGNORECASE).match?(name)
    rescue RegexpError
      false
    end
    matched
  end

  def serialize_for_client
    {
      hidden_agenda_ids:     hidden_agenda_ids.map(&:to_i),
      hidden_schedule_ids:   hidden_schedule_ids.map(&:to_i),
      hidden_schedule_names: hidden_schedule_name_map,
      hidden_item_ids:       hidden_item_ids.map(&:to_i),
      hidden_item_names:     hidden_item_name_map,
      hidden_name_patterns:  hidden_name_patterns,
      hide_completed:        KIND_KEYS.index_with { |k| hide_completed_for?(k) },
      hide_tentative:        !!hide_tentative,
    }
  end

  # Push the latest snapshot to every connected client for this user, so a
  # filter change on phone is reflected on laptop immediately. Reuses the
  # `:agenda` channel — clients already listen for that and re-apply filters
  # on any payload that carries `preferences`.
  def broadcast!
    MonitorChannel.broadcast_to(user, {
      id:        :agenda,
      channel:   :agenda,
      timestamp: Time.current.to_i,
      data:      { preferences: serialize_for_client },
    })
  end

  private

  # Names keyed by id so the filter panel can render an "unhide" list even
  # for schedules whose only items have already been filtered out of view.
  def hidden_schedule_name_map
    return {} if hidden_schedule_ids.blank?
    AgendaSchedule.where(id: hidden_schedule_ids).pluck(:id, :name).to_h
  end

  def hidden_item_name_map
    return {} if hidden_item_ids.blank?
    AgendaItem.where(id: hidden_item_ids).pluck(:id, :name).to_h
  end

  def validate_pattern_compiles
    Array(hidden_name_patterns).each do |src|
      Regexp.new(src.to_s)
    rescue RegexpError => e
      errors.add(:hidden_name_patterns, "invalid regex #{src.inspect}: #{e.message}")
    end
  end
end
