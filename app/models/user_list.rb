# == Schema Information
#
# Table name: user_lists
#
#  id         :integer          not null, primary key
#  user_id    :integer
#  list_id    :integer
#  is_owner   :boolean
#  sort_order :integer
#

class UserList < ApplicationRecord

  belongs_to :user
  belongs_to :list

  before_save :set_sort_order
  after_commit :reorder_conflict_orders

  private

  def set_sort_order
    self.sort_order ||= user.user_lists.where.not(id: [nil, id]).max_by(&:sort_order).try(:sort_order).to_i + 1
  end

  def reorder_conflict_orders
    conflicted_lists = user.user_lists.where.not(id: self.id).where(sort_order: self.sort_order)

    conflicted_lists.each do |conflicted_item|
      conflicted_lists.update(sort_order: conflicted_item.sort_order + 1)
    end
  end

end
