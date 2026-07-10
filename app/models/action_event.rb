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

  search_terms :id, :name, :notes, :timestamp, data_source: :search_data_source

  # Sources are stored as top-level truthy keys on `data` (e.g. `{ phone:
  # true, car: true, lat, lng }`) so a single event can accumulate multiple
  # reporters. Query matches events whose data has any of the given source
  # keys.
  scope :search_data_source, ->(*sources) {
    where("data ?| array[:sources]", sources: Array.wrap(sources).flatten.compact.map(&:to_s))
  }
  # Contains ANY
  scope :search_data_actions_any, ->(*qs) {
    where("data -> 'actions' ?| array[:actions]", actions: Array.wrap(qs).flatten.compact)
  }
  # Contains ALL
  scope :search_data_actions_all, ->(*qs) {
    where("data @> ?", { actions: Array.wrap(qs).flatten.compact }.to_json)
  }
end
