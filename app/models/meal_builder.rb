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

  validates :name, :parameterized_name, presence: true

  before_validation -> { self.parameterized_name = name.parameterize }

  json_attributes :items

  def to_param
    parameterized_name
  end

  def items=(items_list)
    return super unless items_list.is_a?(String) # rubocop:disable Lint/ReturnInVoidContext

    self.items = items_list.split(/\r?\n\r?/).map { |line|
      match = line.match(/^(?<category>[^ ]+)?\s+(?<name>[^()]+)\s*(?:\((?<cal>\d+)\))?\s*(?<img>[^|]*?)(?:\|\s*(?<tag>.*?))?$/)

      next unless match

      {
        category: match[:category].presence || "Food",
        name:     match[:name].squish,
        cal:      match[:cal].to_i,
        img:      match[:img],
        tag:      match[:tag],
      }
    }.compact
  end

  # The builder a logged thing of `category` belongs on: the one named for it
  # (a Drink builder for drinks), else Food, else whichever came first.
  def self.for_category(category)
    builders = order(:id).to_a
    builders.detect { |b| b.name.casecmp?(category.to_s) } ||
      builders.detect { |b| b.name.casecmp?("Food") } ||
      builders.first
  end

  # One more thing to pick. A name already on it, in any case, is left as it
  # is rather than listed twice. Returns whether it is on the builder now.
  def add_item!(category:, name:, cal:)
    name = name.to_s.squish
    return false if name.blank?
    return true if items.any? { |item| item[:name].to_s.casecmp?(name) }

    item = { category: category.to_s.squish.capitalize.presence || "Food", name: name, cal: cal.to_i, img: emoji_for(name), tag: "" }
    update!(items: items + [item])
    true
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

  private

  # An emoji, not a Tabler class name or an uploaded icon - the builder draws
  # all three, but a guess made from the name alone is best as the glyph.
  def emoji_for(name)
    values = ::IconPool.search(name, limit: 10).pluck(:c)
    values.find { |value| value.present? && !value.start_with?("ti-", "data:") }.to_s
  end
end
