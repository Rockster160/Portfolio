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

  enum :answer_type, {
    single: 0,
    many:   1,
  }

  def serialize(opts={})
    super.merge(
      url: persisted? ? Rails.application.routes.url_helpers.prompt_url(self) : nil,
    )
  end
end
