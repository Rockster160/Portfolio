# == Schema Information
#
# Table name: tags
#
#  id         :bigint           not null, primary key
#  name       :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class Tag < ApplicationRecord
  has_many :page_tags
  has_many :folder_tags
  has_many :pages, through: :page_tags
  has_many :folders, through: :folder_tags
end
