# == Schema Information
#
# Table name: list_items
#
#  id         :integer          not null, primary key
#  name       :string(255)
#  list_id    :integer
#  created_at :datetime
#  updated_at :datetime
#

class ListItem < ActiveRecord::Base
  belongs_to :list
end
