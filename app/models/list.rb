# == Schema Information
#
# Table name: lists
#
#  id         :integer          not null, primary key
#  name       :string(255)
#  created_at :datetime
#  updated_at :datetime
#

class List < ActiveRecord::Base
  has_many :list_items
end
