# Hands what was said on a Feature Builder's PR to its session, once the
# feedback has gone quiet (FeatureBuilder::GATHER_FOR). Each comment queues one
# of these; whichever runs after the last comment sends the lot, and the rest
# find nothing waiting.
#
# The prompt is hidden: the thread already shows each comment as it came in.
class FeatureBuilderFeedbackWorker
  include Sidekiq::Worker

  # A retry would type the same feedback into the session twice.
  sidekiq_options queue: :default, retry: false

  def perform(conversation_id)
    conversation = ByteConversation.builder.find_by(id: conversation_id)
    return if conversation.nil?

    # Two of these can wake together; only one may take the waiting comments.
    prompt = conversation.with_lock { FeatureBuilder.gather!(conversation) }
    return if prompt.nil?

    ByteMessageIntake.call(
      user:         conversation.user,
      conversation: conversation,
      body:         prompt,
      metadata:     { "pr_feedback_prompt" => true, "hidden" => true },
    )
  end
end
