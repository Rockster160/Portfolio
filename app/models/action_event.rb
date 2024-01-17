# == Schema Information
#
# Table name: action_events
#
#  id            :integer          not null, primary key
#  data          :jsonb
#  name          :text
#  notes         :text
#  streak_length :integer
#  timestamp     :datetime
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :integer
#

class ActionEvent < ApplicationRecord
  belongs_to :user

  validates :name, presence: true

  before_save { self.timestamp ||= Time.current }

  search_terms :name, :notes

  def timestamp=(str_stamp)
    return if str_stamp.blank?

    super(str_stamp.in_time_zone("Mountain Time (US & Canada)"))
  end

  def self.serialize
    all.as_json(only: [:id, :name, :notes, :timestamp, :data])
  end

  def serialize
    as_json(only: [:id, :name, :notes, :timestamp, :data])
  end
end
