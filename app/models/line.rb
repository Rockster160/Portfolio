# == Schema Information
#
# Table name: lines
#
#  id            :integer          not null, primary key
#  flash_card_id :integer
#  text          :string(255)
#  center        :boolean
#  created_at    :datetime
#  updated_at    :datetime
#

class Line < ApplicationRecord

  belongs_to :flash_card
  default_scope { order('id ASC') }
  
end
