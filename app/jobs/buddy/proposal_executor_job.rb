module Buddy
  class ProposalExecutorJob < ApplicationJob
    queue_as :default

    def perform(byte_action_id, execute_ids=nil)
      Buddy::ProposalExecutor.perform(byte_action_id, execute_ids)
    end
  end
end
