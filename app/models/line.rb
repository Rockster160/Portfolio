# == Schema Information
#
# Table name: lines
#
#  id            :integer          not null, primary key
#  center        :boolean
#  text          :string(255)
#  created_at    :datetime
#  updated_at    :datetime
#  flash_card_id :integer
#

class Line < ApplicationRecord
  belongs_to :flash_card
  default_scope { order(:id) }
end
