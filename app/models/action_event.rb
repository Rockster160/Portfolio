# == Schema Information
#
# Table name: action_events
#
#  id         :integer          not null, primary key
#  event_name :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :integer
#

class ActionEvent < ApplicationRecord
  belongs_to :user
end
