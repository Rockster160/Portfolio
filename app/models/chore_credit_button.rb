# == Schema Information
#
# Table name: chore_credit_buttons
#
#  id                 :bigint           not null, primary key
#  color              :text
#  label              :text             not null
#  sort_order         :integer
#  tag                :text
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  chore_household_id :bigint           not null
#  chore_id           :bigint           not null
#  created_by_user_id :bigint           not null
#  credit_user_id     :bigint           not null
#

# A custom board button that, on a press, marks one chore done and credits a
# chosen household member for it — the "Dishes, by Chelsea" button beside the
# "Dishes, by me" one. The chore system already lands pebbles, streak and that
# person's automations on whoever is credited (ChoreCompleter's `user:`), so
# this only has to say WHICH chore and WHO: the press records a completion for
# `credit_user`, recorded_by whoever tapped.
#
# Household-scoped and grouped by `tag`, exactly like the chores it completes, so
# a shared board shows the same buttons to everyone in the house. It touches
# nothing about the thread it is pressed on — not the pet, not the pinned/primary
# conversation — so a board is only ever a board, whichever Buddy is wearing it.
class ChoreCreditButton < ApplicationRecord
  belongs_to :chore_household
  belongs_to :created_by_user, class_name: "User"
  belongs_to :chore
  belongs_to :credit_user, class_name: "User"

  validates :label, presence: true
  validate  :chore_in_household
  validate  :credit_user_in_household

  # The chores one board is responsible for, matched case-insensitively like
  # Chore.tagged — the tag is typed, and "Shared" and "shared" are one group.
  scope :tagged,    ->(tag) { where("LOWER(chore_credit_buttons.tag) = ?", tag.to_s.downcase.strip) }
  scope :tag_names, -> { where.not(tag: [nil, ""]).distinct.pluck(:tag).sort_by(&:downcase) }
  # A board's buttons, in the order they were added.
  scope :for_board, ->(tag) { tagged(tag).order(Arel.sql("sort_order ASC NULLS LAST, id ASC")) }

  # How the board draws it: a stateless "tap to credit" circle. Carries its own
  # colour and the ids a press needs; `short_name` mirrors the field a chore cell
  # reads for its title and first-letter fallback, so the client paints it the
  # same way without a special case.
  def board_item
    {
      kind:           :credit,
      id:             id,
      name:           label,
      short_name:     label,
      color:          color.presence,
      icon:           nil,
      icon_kind:      :empty,
      chore_id:       chore_id,
      credit_user_id: credit_user_id,
    }
  end

  private

  def chore_in_household
    return if chore.nil? || chore.chore_household_id == chore_household_id

    errors.add(:chore, "must be in the same household")
  end

  def credit_user_in_household
    return if credit_user.nil? || credit_user.chore_household_id == chore_household_id

    errors.add(:credit_user, "must be in the same household")
  end
end
