# == Schema Information
#
# Table name: pages
#
#  id         :bigint           not null, primary key
#  content    :text
#  title      :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class Page < ApplicationRecord
  belongs_to :user
  has_many :page_tags
  has_many :tags, through: :page_tags

  def tag_strings
    tags.map(&:name).join(", ")
  end

  def tag_strings=(new_strings)
    new_tag_names = new_strings.split(",").map { |str| str.strip.presence }.compact
    tag_objects = new_tag_names.map do |tag_name|
      Tag.find_or_create_by(name: tag_name.downcase)
    end
    self.tags = tag_objects
    removed_tags = tags - tag_objects
    removed_tags.each { |tag| tags.delete(tag) }
    new_strings
  end
end
