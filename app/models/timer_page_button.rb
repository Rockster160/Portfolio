# == Schema Information
#
# Table name: timer_page_buttons
#
#  id            :bigint           not null, primary key
#  color         :text
#  label         :text             default(""), not null
#  sort_order    :integer          default(0), not null
#  target_url    :text             not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  timer_page_id :bigint           not null
#
class TimerPageButton < ApplicationRecord
  # `touch: true` so the parent page's updated_at bumps whenever a
  # button is created / updated / destroyed. Buttons are nested under
  # the page in the bootstrap payload, so without this the FE's
  # cache-vs-bootstrap reconciliation (which compares page.updated_at)
  # silently keeps a stale cached page that doesn't include the new
  # button.
  belongs_to :timer_page, touch: true

  scope :ordered, -> { order(:sort_order, :id) }
end
