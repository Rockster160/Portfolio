# == Schema Information
#
# Table name: recipe_favorites
#
#  id              :integer          not null, primary key
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  favorited_by_id :integer
#  recipe_id       :integer
#

class RecipeFavorite < ApplicationRecord
  belongs_to :recipe
  belongs_to :favorited_by, class_name: "User"
end
