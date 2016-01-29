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

class FlashCard < ActiveRecord::Base

  default_scope { order('id ASC') }

  has_many :lines, dependent: :destroy
  belongs_to :batch

  after_create :createLines

  def next
    self.class.where("id > ?", id).first || self.class.first
  end

  def previous
    self.class.where("id < ?", id).last || self.class.last
  end

  def createLines
    while self.lines.count < 8
      self.lines.create(text: "", center: false)
    end
  end

end
