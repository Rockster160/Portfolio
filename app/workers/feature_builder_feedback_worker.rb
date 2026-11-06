# Hands what was said on a `/feature` build's PR to its session, once the
# feedback has gone quiet (FeatureBuilder::GATHER_FOR). Each comment queues one
# of these; whichever runs after the last comment sends the lot, and the rest
# find nothing waiting.
class FeatureBuilderFeedbackWorker
  include Sidekiq::Worker

  # A retry would type the same feedback into the session twice. A Mini that
  # didn't answer is tried again on a schedule instead, with the feedback
  # still held on the build.
  sidekiq_options queue: :default, retry: false

  RETRY_IN = 5.minutes

  def perform(build_id)
    build = FeatureBuild.find_by(id: build_id)
    return if build.nil? || build.status_finished?

    prompt = FeatureBuilder.gather(build)
    return if prompt.nil?

    sent = build.feedback.length
    return self.class.perform_in(RETRY_IN, build.id) unless ByteLocal.builder(:message, build_id: build.id, text: prompt)

    # Anything that arrived while this was sending stays for the next one.
    build.with_lock { build.update!(feedback: build.feedback.drop(sent)) }
  end
end
