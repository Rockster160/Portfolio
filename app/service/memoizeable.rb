# class Something
#   include Memoizeable
#   attr_accessor :params
#
#   memoize(:parent) { params.delete(:parent) }
#
#   def initialize(data)
#     @params = data
#   end
# end

module Memoizeable
  def self.included(base)
    base.class_eval do
      def self.memoize(memo, &block)
        memo_ivar = :"@#{memo}"
        define_method(memo) do
          return instance_variable_get(memo_ivar) if instance_variable_defined?(memo_ivar)

          instance_variable_set(memo_ivar, self.instance_exec(&block))
        end
      end
    end
  end
end
