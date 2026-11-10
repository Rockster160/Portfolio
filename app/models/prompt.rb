# == Schema Information
#
# Table name: prompts
#
#  id          :bigint           not null, primary key
#  answer_type :integer
#  options     :jsonb
#  params      :jsonb
#  question    :text
#  response    :jsonb
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint
#
class Prompt < ApplicationRecord
  belongs_to :user, inverse_of: :prompts

  # Deleting a prompt is an ending like answering or skipping it, and the only
  # one that fires no Jil trigger — so the form Buddy posted has to be closed
  # from here rather than from Buddy::PromptDelivery.dispatch.
  after_destroy_commit :settle_buddy_forms
  # The count only moves correctly if every ending broadcasts, not just the
  # arrival — answering and deleting both take one off the dashboard title.
  after_commit :broadcast_pending_count
  # A task filling a question in after the form was posted - a guess that takes
  # a while, a duration still running - reaches the form already on screen.
  after_update_commit :push_to_buddy_forms, if: -> {
    response.nil? && (saved_change_to_options? || saved_change_to_question?)
  }

  scope :unanswered, -> { where(response: nil) }

  enum :answer_type, {
    single: 0,
    many:   1,
  }

  def serialize(opts={})
    super.merge(
      url: persisted? ? Rails.application.routes.url_helpers.prompt_url(self) : nil,
    )
  end

  private

  # Gone is as much an ending as answered: the next one in its queue is asked,
  # and a briefing it was holding goes out.
  def settle_buddy_forms
    ::Buddy::PromptDelivery.discard!(user, id)
    ::Buddy::PromptQueue.advance!(user, ::Buddy::PromptQueue.name_of(self))
    ::Buddy::BriefingHold.release!(user)
  end

  def push_to_buddy_forms
    ::Buddy::FormAction.push_prompt!(self)
  end

  def broadcast_pending_count
    ::JarvisChannel.broadcast({ prompt_count: user.prompts.unanswered.count }, user)
  end
end
