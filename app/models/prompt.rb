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

  def settle_buddy_forms
    ::Buddy::PromptDelivery.discard!(user, id)
  end
end
