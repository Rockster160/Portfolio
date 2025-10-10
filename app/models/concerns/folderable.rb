module Folderable
  extend ActiveSupport::Concern

  included do
    orderable sort_order: :asc, scope: ->(obj) { obj.scoped_parent.public_send(obj.class.table_name) }

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
      tag_objects = new_tag_names.map { |tag_name|
        Tag.find_or_create_by(name: tag_name.downcase)
      }
      self.tags = tag_objects
      removed_tags = tags - tag_objects
      removed_tags.each { |tag| tags.delete(tag) }
      new_strings
    end
  end
end
