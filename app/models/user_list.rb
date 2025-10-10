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
  before_save :set_defaults

  private

  def set_defaults
    other_user_lists = user.user_lists.where.not(id: id)

    if default?
      other_user_lists.where(default: true).update_all(default: false)
    elsif other_user_lists.where(default: true).none?
      self.default = true
    end
  end

  def set_sort_order
    self.sort_order ||= user.user_lists.where.not(id: [nil, id]).max_by(&:sort_order).try(:sort_order).to_i + 1
  end
end
