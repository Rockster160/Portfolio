# == Schema Information
#
# Table name: list_items
#
#  id         :integer          not null, primary key
#  name       :string(255)
#  list_id    :integer
#  created_at :datetime
#  updated_at :datetime
#  sort_order :integer
#

class ListItem < ApplicationRecord
  attr_accessor :do_not_broadcast
  belongs_to :list

  before_save :format_words
  before_save :set_sort_order
  after_commit :reorder_conflict_orders
  after_commit :broadcast_commit

  private

  def format_words
    self.name = self.name.squish.split(' ').map(&:capitalize).join(' ')
  end

  def set_sort_order
    self.sort_order ||= list.list_items.count
  end

  def broadcast_commit
    return if do_not_broadcast
    rendered_message = ListsController.render template: "list_items/index", locals: { list: self.list }, layout: false
    ActionCable.server.broadcast "list_channel", list_html: rendered_message
  end

  def reorder_conflict_orders
    conflicted_items = list.list_items.where.not(id: self.id).where(sort_order: self.sort_order)
    if conflicted_items.any?
      do_not_broadcast = true
      conflicted_items.each do |conflicted_item|
        conflicted_items.update(sort_order: conflicted_item.sort_order + 1, do_not_broadcast: true)
      end
    else
      do_not_broadcast = false
    end
  end

end
