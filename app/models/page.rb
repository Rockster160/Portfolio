# == Schema Information
#
# Table name: pages
#
#  id                 :bigint           not null, primary key
#  content            :text
#  name               :string
#  parameterized_name :text
#  sort_order         :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  folder_id          :bigint
#  user_id            :bigint           not null
#
class Page < ApplicationRecord
  include Orderable

  belongs_to :folder, optional: true
  belongs_to :user
  has_many :page_tags
  has_many :tags, through: :page_tags

  orderable sort_order: :asc, scope: ->(page) { page.scoped_parent.pages }

  before_save -> { self.parameterized_name = name.parameterize }

  def breadcrumbs
    parent = folder
    [].tap { |trail|
      loop do
        break if parent.blank?
        trail << parent
        parent = parent.folder
      end
    }
  end

  def scoped_parent
    folder || user
  end

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
