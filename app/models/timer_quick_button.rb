# == Schema Information
#
# Table name: timer_quick_buttons
#
#  id               :bigint           not null, primary key
#  color            :text
#  duration_seconds :integer          not null
#  label            :text
#  pinned           :boolean          default(TRUE), not null
#  sort_order       :integer          default(0), not null
#  template         :jsonb            not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  user_id          :bigint           not null
#
class TimerQuickButton < ApplicationRecord
  belongs_to :user

  validates :duration_seconds, presence: true, numericality: { greater_than: 0 }

  scope :ordered, -> { order(:sort_order, :id) }
end
