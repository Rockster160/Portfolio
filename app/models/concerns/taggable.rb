module Taggable
  extend ActiveSupport::Concern

  included do
    def tag_strings
      tags.map(&:name).join(", ")
    end

    def tag_strings=(new_strings)
      new_tag_names = new_strings.split(",").map { |str| str.strip.downcase.presence }.compact.uniq
      self.tags = new_tag_names.map { |tag_name| Tag.find_or_create_by(name: tag_name) }
      new_strings
    end
  end
end
