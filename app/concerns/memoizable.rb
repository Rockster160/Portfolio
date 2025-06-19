# class Something
#   include Memoizable
#   attr_accessor :params
#
#   💾(:parent) { params.delete(:parent) }
#
#   def initialize(data)
#     @params = data
#   end
# end

module Memoizable
  extend ::ActiveSupport::Concern

  included do
    class << self
      def memoize(memo_key, &block)
        if instance_methods(false).include?(memo_key)
          raise "Attempted to memoize [#{memo_key}], but has already been defined!"
        end

        define_method(memo_key) do
          memo(memo_key: memo_key, &block)
        end
      end

      alias_method :💾, :memoize
    end

    def memo(value=nil, memo_key: nil, &block)
      memo_key ||= caller_locations(1, 1)[0].label
      memo_ivar = :"@#{memo_key.to_s.delete("?")}"
      return instance_variable_get(memo_ivar) if instance_variable_defined?(memo_ivar)
      return instance_variable_set(memo_ivar, instance_exec(&block)) if block_given?

      self.class.define_method(memo_key) do
        instance_variable_get(memo_ivar)
      end

      instance_variable_set(memo_ivar, value)
    end

    alias_method :💾, :memo
  end
end
