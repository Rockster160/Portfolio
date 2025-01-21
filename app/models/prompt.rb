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

  scope :unanswered, -> { where(response: nil) }

  enum answer_type: {
    single: 0,
    many:   1,
  }

  def self.legacy_serialize
    all.map(&:legacy_serialize)
  end

  def legacy_serialize
    {
      id: id,
      question: question,
      params: params,
      options: options,
      response: response,
      url: Rails.application.routes.url_helpers.prompt_url(self)
    }.with_indifferent_access
  end
end
