# == Schema Information
#
# Table name: flash_cards
#
#  id         :integer          not null, primary key
#  batch_id   :integer
#  title      :string(255)
#  body       :text
#  pin        :integer
#  created_at :datetime
#  updated_at :datetime
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
