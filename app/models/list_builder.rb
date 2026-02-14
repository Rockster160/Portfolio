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
      stripped = line.strip
      stock = 0
      if (sm = stripped.match(/\((\d+)\)\s*$/))
        stock = sm[1].to_i
        stripped = stripped.sub(/\s*\(\d+\)\s*$/, "")
      end

      parts = stripped.split("|", 3)
      next if parts[0].blank?

      name = parts[0].squish
      low = nil
      if (lm = name.match(/\[(\d+)\]\s*$/))
        low = lm[1].to_i
        name = name.sub(/\s*\[\d+\]\s*$/, "").squish
      end

      {
        name: name,
        img: parts[1].to_s.strip,
        display: parts[2].to_s.strip.presence,
        stock: stock,
        low: low,
      }.compact
    }.compact
  end

  def listify_items
    items.map { |item|
      name = item[:name]
      name = "#{name} [#{item[:low]}]" if item.key?(:low)
      parts = [name]
      parts << " | #{item[:img]}" if item[:img].present?
      parts << " | #{item[:display]}" if item[:display].present?
      parts << " (#{item[:stock]})" if item[:stock].to_i > 0
      parts.join
    }.join("\n")
  end

  def broadcast!
    ActionCable.server.broadcast(
      "builder_#{id}_channel",
      { builder_items: items }
    )
  end
end
