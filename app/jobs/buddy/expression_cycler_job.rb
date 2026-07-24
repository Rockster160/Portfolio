module Buddy
  class ExpressionCyclerJob < ApplicationJob
    queue_as :default

    def perform(user_id, expression)
      user = User.find_by(id: user_id)
      return if user.nil?

      Buddy::ExpressionState.set(user, expression)
    end
  end
end
