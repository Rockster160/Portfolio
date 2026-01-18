# == Schema Information
#
# Table name: list_builders
#
#  id                 :bigint           not null, primary key
#  items              :jsonb            not null
#  name               :text             not null
#  parameterized_name :text             not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  user_id            :bigint           not null
#  list_id            :bigint           not null
#
class ListBuilder < ApplicationRecord
  belongs_to :user
  belongs_to :list

  validates :name, :parameterized_name, presence: true

  before_validation -> { self.parameterized_name = name.parameterize }

  json_attributes :items

  def to_param
    parameterized_name
  end

  def items=(items_list)
    return super unless items_list.is_a?(String) # rubocop:disable Lint/ReturnInVoidContext

    self.items = items_list.split(/\r?\n\r?/).map { |line|
      match = line.match(/^(?<name>[^|]+?)(?:\|\s*(?<img>.*?))?$/)

      next unless match

      {
        name: match[:name].squish,
        img:  match[:img].to_s.strip,
      }
    }.compact
  end

  def listify_items
    items.map { |item|
      [
        item[:name],
        item[:img].present? ? " | #{item[:img]}" : nil,
      ].compact.join
    }.join("\n")
  end
end
