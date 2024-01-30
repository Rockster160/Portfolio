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
  belongs_to :user
  belongs_to :task, class_name: "JarvisTask"

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
      task: task&.uuid,
      url: Rails.application.routes.url_helpers.jil_prompt_url(self)
    }
  end
end
