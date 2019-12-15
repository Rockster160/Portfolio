# == Schema Information
#
# Table name: user_lists
#
#  id         :integer          not null, primary key
#  user_id    :integer
#  list_id    :integer
#  is_owner   :boolean
#  sort_order :integer
#  default    :boolean          default(FALSE)
#

class UserList < ApplicationRecord
  attr_accessor :do_not_broadcast

  belongs_to :user
  belongs_to :list

  before_save :set_sort_order

  private

  def set_sort_order
    self.sort_order ||= user.user_lists.where.not(id: [nil, id]).max_by(&:sort_order).try(:sort_order).to_i + 1
  end

end
