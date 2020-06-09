# == Schema Information
#
# Table name: recipes
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
#  description  :text
#  friendly_url :string
#

class Recipe < ApplicationRecord
  belongs_to :user, optional: true

  has_many :recipe_shares, dependent: :destroy
  has_many :recipe_favorites, dependent: :destroy

  has_many :shared_users, through: :shares, source: :shared_to
  has_many :favorited_by_users, through: :favorites, source: :favorited_by

  before_save :set_friendly_url

  scope :viewable, lambda { |current_user=nil|
    scopes = [
      "(recipes.public IS true)",
      "(recipes.user_id = :user_id)",
      "(recipe_shares.shared_to_id = :user_id)",
    ]
    includes(:recipe_shares).references(:recipe_shares)
      .where(scopes.join(" OR "), user_id: current_user.try(:id))
  }

  def ingredients_list
    ingredients.to_s.split("\n").map { |ingredient| ingredient.squish.presence }.compact
  end

  def export_to_list(list)
    items = ingredients_list.map { |ingredient| {name: "#{ingredient} (#{title})"} }
    list.add_items(items)
  end

  def to_param
    friendly_url
  end

  private

  def set_friendly_url
    try_url = title.to_s.parameterize.first(50)
    iteration = nil

    self.friendly_url = loop do
      iteration_url = [try_url, iteration].compact.join("-")
      break iteration_url if self.class.where(friendly_url: iteration_url).where.not(id: id).none?
      iteration ||= 1
      iteration += 1
    end
  end
end
