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

class ListItem < ApplicationRecord
  belongs_to :list

  before_save :format_words
  after_commit :broadcast_commit

  private

  def broadcast_commit
    rendered_message = ListsController.render template: "list_items/index", locals: { list: self.list }, layout: false
    ActionCable.server.broadcast "list_channel", list_html: rendered_message
  end

  def format_words
    self.name = self.name.squish.split(' ').map(&:capitalize).join(' ')
  end

end
