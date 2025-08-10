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

    self.items = items_list.split(/\r?\n\r?/).map { |line|
      match = line.match(/^(?<category>[^ ]+)?\s+(?<name>[^()]+)\s*(?:\((?<cal>\d+)\))?\s*(?<img>[^\|]*?)(?:\|\s*(?<tag>.*?))?$/)

      if match
        {
          category: match[:category].presence || "Food",
          name: match[:name].squish,
          cal: match[:cal].to_i,
          img: match[:img],
          tag: match[:tag],
        }
      end
    }.compact
  end

  def listify_items
    items.map { |item|
      [
        item[:category],
        item[:name],
        "(#{item[:cal].to_s.squish})",
        item[:img],
        item[:tag].present? ? " | #{item[:tag]}" : nil,
      ].map { |part| part.to_s.squish }.compact_blank.join(" ")
    }.join("\n")
  end
end
