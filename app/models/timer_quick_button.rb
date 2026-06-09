# == Schema Information
#
# Table name: timer_quick_buttons
#
#  id               :bigint           not null, primary key
#  color            :text
#  duration_seconds :integer
#  label            :text
#  pinned           :boolean          default(TRUE), not null
#  sort_order       :integer          default(0), not null
#  template         :jsonb            not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  timer_page_id    :bigint
#  user_id          :bigint           not null
#
class TimerQuickButton < ApplicationRecord
  belongs_to :user
  # NULL = the user's defaults shown on Home. Non-null = page-specific.
  # Each TimerPage gets its own copy of the defaults the first time it's
  # rendered (see TimersController#ensure_page_quick_buttons!), so edits
  # on a page don't bleed back into Home or sibling pages.
  belongs_to :timer_page, optional: true

  # Only countdown templates carry a duration. A "Save as template"
  # off a dial or counter has no countdown duration — let those rows
  # save with a nil. When present, must be positive.
  validates :duration_seconds, numericality: { greater_than: 0, allow_nil: true }

  scope :ordered,       -> { order(:sort_order, :id) }
  scope :user_defaults, -> { where(timer_page_id: nil) }
  scope :for_page,      ->(page_id) { where(timer_page_id: page_id) }
end
