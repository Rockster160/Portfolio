# == Schema Information
#
# Table name: household_glossary_terms
#
#  id                 :bigint           not null, primary key
#  chore_household_id :bigint
#  term               :text             not null
#  meaning            :text             not null
#  aliases            :jsonb            not null
#  kind               :integer
#  notes              :text
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#
class HouseholdGlossaryTerm < ApplicationRecord
  belongs_to :chore_household

  # What sort of thing the word points at. Mostly this exists so the prompt can
  # group the list — a wall of forty unsorted definitions reads as noise, and
  # "these five are people, these three are places" reads as a map.
  #
  # `device` is here for the household radar: sensors, lights, and doors get
  # their alias sets from the same table, because "the front door" being the
  # same thing as "the doorbell" is exactly the kind of fact this holds.
  enum :kind, {
    person:    0,
    pet:       1,
    place:     2,
    thing:     3,
    activity:  4,
    device:    5,
    shorthand: 6,
  }, prefix: :kind

  validates :term, presence: true, length: { maximum: 80 }
  validates :meaning, presence: true, length: { maximum: 300 }

  before_validation :tidy_aliases

  scope :ordered, -> { order(Arel.sql("kind NULLS LAST, LOWER(term)")) }

  KIND_LABELS = {
    "person"    => "People",
    "pet"       => "Pets",
    "place"     => "Places",
    "thing"     => "Things",
    "activity"  => "Activities",
    "device"    => "Devices & sensors",
    "shorthand" => "Shorthand",
  }.freeze

  def kind_label
    KIND_LABELS[kind] || "Other"
  end

  # Every string that should resolve to this entry, the term itself included.
  def names
    ([term] + Array(aliases)).compact_blank.uniq
  end

  # Find the entry a phrase refers to. Exact (case-insensitive) on any of the
  # names first, then a whole-word appearance inside a longer sentence — "did
  # you feed the puppy" has to reach Whisper, and "puppy" alone has to not match
  # "puppylike".
  #
  # Deliberately not fuzzy. A glossary that guesses is worse than one that
  # doesn't answer, because a wrong translation is invisible downstream.
  def self.lookup(household, phrase)
    text = phrase.to_s.strip.downcase
    return nil if text.empty? || household.nil?

    rows = where(chore_household_id: household.id).to_a
    rows.detect { |r| r.names.any? { |n| n.downcase == text } } ||
      rows.detect { |r| r.names.any? { |n| text.match?(/\b#{Regexp.escape(n.downcase)}\b/) } }
  end

  private

  def tidy_aliases
    self.aliases = Array(aliases).map { |a| a.to_s.strip }.compact_blank.uniq
  end
end
