class FlashCard < ActiveRecord::Base
  after_create :createLines
  default_scope { order('id ASC') }
  has_many :lines, dependent: :destroy

  def createLines
    while self.lines.count < 8
      self.lines.create(text: "", center: false)
    end
  end
end
