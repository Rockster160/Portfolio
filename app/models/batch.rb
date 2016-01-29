# == Schema Information
#
# Table name: batches
#
#  id         :integer          not null, primary key
#  text       :string(255)
#  created_at :datetime
#  updated_at :datetime
#

class Batch < ActiveRecord::Base

  has_many :flash_cards
  
end
