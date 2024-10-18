# == Schema Information
#
# Table name: jil_prompts
#
#  id          :bigint           not null, primary key
#  answer_type :integer
#  options     :jsonb
#  params      :jsonb
#  question    :text
#  response    :jsonb
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  task_id     :bigint
#  user_id     :bigint
#
class JilPrompt < ApplicationRecord
  belongs_to :user, inverse_of: :prompts

  scope :unanswered, -> { where(response: nil) }

  enum answer_type: {
    single: 0,
    many:   1,
  }

  def self.serialize
    all.map(&:serialize)
  end

  def serialize
    {
      id: id,
      question: question,
      params: params,
      options: options,
      response: response,
      url: Rails.application.routes.url_helpers.jil_prompt_url(self)
    }.with_indifferent_access
  end
end
