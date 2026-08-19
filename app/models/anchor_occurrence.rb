# == Schema Information
#
# Table name: anchor_occurrences
#
#  id         :bigint           not null, primary key
#  identifier :text
#  occurs_at  :datetime         not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  anchor_id  :bigint           not null
#

# One upcoming time on an Anchor.
#
# Saving one is what announces that the anchor moved, so anything scheduled
# against it re-resolves without the writer having to remember to ask. Same
# shape as AgendaItem propagating to its derived triggers when start_at shifts -
# the thing that changed tells its dependents, rather than dependents polling.
class AnchorOccurrence < ApplicationRecord
  belongs_to :anchor, inverse_of: :occurrences

  validates :occurs_at, presence: true
  validates :identifier, uniqueness: { scope: :anchor_id }, allow_nil: true

  # Two callbacks, two method names on purpose: after_*_commit registrations are
  # keyed by method, so pointing both at one name would silently keep only the
  # last and drop the other event.
  after_commit :propagate_move, on: [:create, :update], if: :saved_change_to_occurs_at?
  after_commit :propagate_removal, on: :destroy

  private

  def propagate_move
    propagate
  end

  def propagate_removal
    propagate
  end

  # Nothing to tell when the anchor itself is going away - the cascade is
  # deleting every occurrence, and each one would otherwise re-propagate against
  # a record that's already destroyed.
  def propagate
    return if anchor.nil? || anchor.destroyed?

    anchor.propagate!
  end
end
