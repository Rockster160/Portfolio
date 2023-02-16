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

  search_terms(
    :notes,
    name: :event_name,
  )

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
