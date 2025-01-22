module Orderable
  extend ActiveSupport::Concern

  included do
    @orderable_scope = nil
    @orderable_by_key = nil
    @orderable_by_dir = :ASC

    def self.orderable_vars
      {
        scope: @orderable_scope,
        key: @orderable_by_key,
        dir: @orderable_by_dir,
      }
    end

    def self.orderable_by(attr)
      key, dir = *attr.to_a.first if attr.is_a?(Hash)
      @orderable_by_key = key || attr
      @orderable_by_dir = ([dir&.upcase&.to_sym] & [:DESC, :ASC]).first || :ASC
    end

    def self.orderable_scope(method=nil, &block)
      @orderable_scope = method || block
    end

    # ordereable :sort_order
    # ordereable sort_order: :asc
    # ordereable sort_order: :desc, scope: -> { task.owner.tasks }
    def self.orderable(opts={})
      set_scope = opts.delete(:scope)
      orderable_by(opts) if opts.present?
      orderable_scope(set_scope) if set_scope
      # Don't apply default scope since you have to then unscope to do any other ordering
      # default_scope { ordered }
    end

    def orderable_ordered
      if self.class.orderable_vars[:scope].is_a?(Proc)
        self.class.orderable_vars[:scope].call(self)
      elsif self.class.orderable_vars[:scope].present?
        send(self.class.orderable_vars[:scope])
      else
        self.class.all
      end
    end

    # Set default order column to `sort_order`
    orderable_by(:sort_order) unless @orderable_by_key.present?
    before_save :set_orderable # Callback to set the order column
    scope :ordered, -> { # Add a scope that can be used to return in order
      order(orderable_vars[:key] => orderable_vars[:dir])
    }

    def set_orderable
      self[self.class.orderable_vars[:key]] ||= orderable_ordered.maximum(self.class.orderable_vars[:key]).to_i + 1
    end
  end
end
