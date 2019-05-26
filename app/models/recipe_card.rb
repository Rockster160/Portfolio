# == Schema Information
#
# Table name: recipe_cards
#
#  id           :integer          not null, primary key
#  user_id      :integer
#  title        :string
#  kitchen_of   :string
#  ingredients  :text
#  instructions :text
#  public       :boolean
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#

class RecipeCard < ApplicationRecord
  belongs_to :user, optional: true

  def ingredients_list
    ingredients.to_s.split("\n").map { |ingredient| ingredient.squish.presence }
  end

  def export_to_list(list)
    items = ingredients_list.map { |ingredient| {name: "#{ingredient} (#{title})"} }
    list.add_items(items)
  end
end
