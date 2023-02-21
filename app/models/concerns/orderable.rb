module Orderable
  extend ActiveSupport::Concern

  included do
    @@orderable_scope = nil
    @@orderable_by = nil

    def self.orderable_by(attr)
      @@orderable_by = attr
    end

    def self.orderable_scope(method=nil, &block)
      @@orderable_scope = method || block
    end

    def self.orderable_ordered
      if @@orderable_scope.is_a?(Proc)
        @@orderable_scope.call
      elsif @@orderable_scope.present?
        send(@@orderable_scope)
      else
        all
      end
    end

    orderable_by(:sort_order) # Set default order column to `sort_order`
    before_save :set_orderable # Callback to set the order column
    scope :ordered, -> { sort(@@orderable_by) } # Add a scope that can be used to return in order

    def set_orderable
      self[@@orderable_by] ||= self.class.orderable_ordered.maximum(@@orderable_by).to_i + 1
    end
  end
end
