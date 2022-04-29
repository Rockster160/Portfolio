# == Schema Information
#
# Table name: surveys
#
#  id                :integer          not null, primary key
#  description       :text
#  name              :text
#  randomize_answers :boolean          default(TRUE)
#  slug              :text
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

class Survey < ApplicationRecord
  has_many :survey_results
  has_many :survey_result_details
  has_many :survey_questions
  has_many :survey_question_answers
  has_many :survey_question_answer_results
  has_many :user_surveys
  has_many :user_survey_responses

  before_save :set_slug

  enum score_type: {
    aggregate:  0,
    accumulate: 1,
  }

  def questions
    survey_questions.order(:position)
  end

  private

  def set_slug
    i = 1
    self.slug ||= loop do
      slug = "#{"#{i}-" if i > 1}#{name.parameterize}"
      break slug unless self.class.where(slug: slug).any?
      i += 1
    end
  end
end
