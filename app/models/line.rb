class Line < ActiveRecord::Base
  belongs_to :flash_card
  default_scope { order('id ASC') }
end
