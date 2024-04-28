module Memoizeable
  def self.included(base)
    base.class_eval do
      def self.memoize(memos)
        memos.each do |memo, block|
          memo_ivar = :"@#{memo}"
          define_method(memo) do
            return instance_variable_get(memo_ivar) if instance_variable_defined?(memo_ivar)

            res = self.instance_exec(&block)
            instance_variable_set(memo_ivar, res)
          end
        end
      end
    end
  end
end
