# == Schema Information
#
# Table name: flash_cards
#
#  id         :integer          not null, primary key
#  body       :text
#  pin        :integer
#  title      :string(255)
#  created_at :datetime
#  updated_at :datetime
#  batch_id   :integer
#

class FlashCard < ApplicationRecord

  default_scope { order('id ASC') }

  has_many :lines, dependent: :destroy
  belongs_to :batch

  after_create :createLines

  def next
    self.class.find_by("id > ?", id) || self.class.first
  end

  def previous
    self.class.find_by("id < ?", id) || self.class.last
  end

  def createLines
    while self.lines.count < 8
      self.lines.create(text: "", center: false)
    end
  end

end
