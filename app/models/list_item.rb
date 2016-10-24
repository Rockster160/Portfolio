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

  before_save :format_words

  private

  def format_words
    self.name = self.name.squish.split(' ').map(&:capitalize).join(' ')
  end

end
