# == Schema Information
#
# Table name: meal_builders
#
#  id                 :bigint           not null, primary key
#  items              :jsonb            not null
#  name               :text             not null
#  parameterized_name :text             not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  user_id            :bigint           not null
#
class MealBuilder < ApplicationRecord
  belongs_to :user

  validates_presence_of :name, :parameterized_name

  before_validation -> { self.parameterized_name = name.parameterize }

  json_attributes :items

  def to_param
    parameterized_name
  end

  def items=(items_list)
    return super(items_list) unless items_list.is_a?(String)

    self.items = items_list.split("\n").map { |line|
      match = line.match(/^(?<category>[^ ]+)\s+(?<name>.+?)\s+\((?<cal>\d+)\)\s*(?<img>.+)?/)

      if match
        {
          category: match[:category],
          name: match[:name],
          cal: match[:cal].to_i,
          img: match[:img]
        }
      end
    }.compact
  end

  def listify_items
    items.map { |item|
      "#{item[:category]} #{item[:name]} (#{item[:cal]}) #{item[:img]}".squish
    }.join("\n")
  end
end
