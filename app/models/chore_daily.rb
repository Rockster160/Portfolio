# == Schema Information
#
# Table name: chore_dailies
#
#  id         :bigint           not null, primary key
#  sort_order :integer          default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  chore_id   :bigint           not null
#  user_id    :bigint           not null
#
# Per-user pinned-on-Today entry for a chore. Users curate their own
# Dailies list — what shows up there is purely a user choice, never
# derived from `show_on_daily_view` or completion state. The Today
# tab's "Overdue" section is the OLD Today list minus these pins.
class ChoreDaily < ApplicationRecord
  belongs_to :user
  belongs_to :chore

  validates :chore_id, uniqueness: { scope: :user_id }

  scope :for_user, ->(user) { where(user_id: user.id).order(:sort_order, :id) }
end
