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
  end
end
