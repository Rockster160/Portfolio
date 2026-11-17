# == Schema Information
#
# Table name: recipe_shares
#
#  id           :integer          not null, primary key
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  recipe_id    :integer
#  shared_to_id :integer
#

class RecipeShare < ApplicationRecord
  belongs_to :recipe
  belongs_to :shared_to, class_name: "User"
end
