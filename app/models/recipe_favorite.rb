# == Schema Information
#
# Table name: recipe_favorites
#
#  id              :integer          not null, primary key
#  recipe_id       :integer
#  favorited_by_id :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#

class RecipeFavorite < ApplicationRecord
  belongs_to :recipe
  belongs_to :favorited_by, class_name: "User"
end
