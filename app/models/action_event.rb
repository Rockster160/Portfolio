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

  before_save { self.timestamp ||= ::Time.current }

  search_terms :id, :name, :notes, :timestamp

  # Contains ANY
  scope :search_data_actions_any, ->(*qs) {
    where("data -> 'actions' ?| array[:actions]", actions: Array.wrap(qs).flatten.compact)
  }
  # Contains ALL
  scope :search_data_actions_all, ->(*qs) {
    where("data @> ?", { actions: Array.wrap(qs).flatten.compact }.to_json)
  }
end
