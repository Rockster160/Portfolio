# == Schema Information
#
# Table name: user_lists
#
#  id       :integer          not null, primary key
#  user_id  :integer
#  list_id  :integer
#  is_owner :boolean
#

class UserList < ApplicationRecord

  belongs_to :user
  belongs_to :list

end
