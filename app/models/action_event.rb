# == Schema Information
#
# Table name: action_events
#
#  id            :integer          not null, primary key
#  event_name    :text
#  notes         :text
#  streak_length :integer
#  timestamp     :datetime
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :integer
#

class ActionEvent < ApplicationRecord
  attr_accessor :do_not_broadcast
  belongs_to :user

  validates :event_name, presence: true

  before_save { self.timestamp ||= Time.current }
  after_create :broadcast_create

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

  def broadcast_create
    return if do_not_broadcast

    JarvisTriggerWorker.perform_async(:log.to_s,
      {
        input_vars: { "Log Name": event_name, "Log Notes": notes }
      }.to_json,
      { user: user_id }.to_json
    )
  end
end
