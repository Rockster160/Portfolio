# == Schema Information
#
# Table name: action_events
#
#  id         :integer          not null, primary key
#  event_name :text
#  notes      :text
#  timestamp  :datetime
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :integer
#

class ActionEvent < ApplicationRecord
  belongs_to :user

  validates :event_name, presence: true

  before_save { self.timestamp ||= Time.current }

  scope :search, ->(q) { ilike(event_name: "%#{q}%", notes: "%#{q}%") }
  scope :name_search, ->(q) { ilike(event_name: "%#{q}%") }
  scope :note_search, ->(q) { ilike(notes: "%#{q}%") }
  scope :unsearch, ->(q) { not_ilike(event_name: "%#{q}%", notes: "%#{q}%") }
  scope :unname_search, ->(q) { not_ilike(event_name: "%#{q}%") }
  scope :unnote_search, ->(q) { not_ilike(notes: "%#{q}%") }
  scope :query, ->(q) {
    data = q.is_a?(Hash) ? q : SearchParser.call(
      q,
      or: "OR:",
      not: "!",
      contains: ":",
      not_contains: "!:",
      not_exact: "!::",
      exact: "::",
      similar: "~",
    )

    #   ~   - similar? (95% text match?)

    built = all
    data.dig(:terms)&.each { |word| built = built.search(word) }
    data.dig(:props, :not)&.each { |word| built = built.unsearch(word) }

    data.dig(:props, :contains, :terms)&.each { |word| built = built.search(word) }
    data.dig(:props, :contains, :props, :name)&.each { |word| built = built.name_search(word) }
    data.dig(:props, :contains, :props, :notes)&.each { |word| built = built.note_search(word) }
    data.dig(:props, :not_contains, :terms)&.each { |word| built = built.unsearch(word) }
    data.dig(:props, :not_contains, :props, :name)&.each { |word| built = built.unname_search(word) }
    data.dig(:props, :not_contains, :props, :notes)&.each { |word| built = built.unnote_search(word) }

    data.dig(:props, :exact, :terms)&.each { |word| built = built.ilike(event_name: word, notes: word) }
    data.dig(:props, :exact, :props, :name)&.each { |word| built = built.ilike(event_name: word) }
    data.dig(:props, :exact, :props, :notes)&.each { |word| built = built.ilike(notes: word) }
    data.dig(:props, :not_exact, :terms)&.each { |word| built = built.not_ilike(event_name: word, notes: word) }
    data.dig(:props, :not_exact, :props, :name)&.each { |word| built = built.not_ilike(event_name: word) }
    data.dig(:props, :not_exact, :props, :notes)&.each { |word| built = built.not_ilike(notes: word) }

    data.dig(:props, :or, :terms)&.each do |or_groups|
      sql_chunks = or_groups.map { |or_group| unscoped.query(or_group).stripped_sql }
      built = built.where("(#{sql_chunks.join(" OR ")})")
    end
    built
  }

  def self.stripped_sql
    all.to_sql.gsub("SELECT \"#{table_name}\".* FROM \"#{table_name}\" WHERE ", "")
  end

  def timestamp=(str_stamp)
    return if str_stamp.blank?

    super(str_stamp.in_time_zone("Mountain Time (US & Canada)"))
  end

  def self.serialize
    all.as_json(only: [:event_name, :notes, :timestamp])
  end

  def serialize
    as_json(only: [:event_name, :notes, :timestamp])
  end
end
