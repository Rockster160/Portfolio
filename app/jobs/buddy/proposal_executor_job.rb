module Buddy
  class ProposalExecutorJob < ApplicationJob
    queue_as :default

    def perform(byte_action_id)
      Buddy::ProposalExecutor.perform(byte_action_id)
    end
  end
end
