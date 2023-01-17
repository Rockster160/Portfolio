# == Schema Information
#
# Table name: surveys
#
#  id                :integer          not null, primary key
#  description       :text
#  name              :text
#  randomize_answers :boolean          default(TRUE)
#  score_type        :integer          default("aggregate")
#  slug              :text
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

class Survey < ApplicationRecord
  has_many :survey_results, dependent: :destroy
  has_many :survey_result_details, dependent: :destroy
  has_many :survey_questions, dependent: :destroy
  has_many :survey_question_answers, dependent: :destroy
  has_many :survey_question_answer_results, dependent: :destroy
  has_many :user_surveys, dependent: :destroy
  has_many :user_survey_responses, dependent: :destroy

  before_save :set_slug

  enum score_type: {
    aggregate:  0, # give a percentage of each result type
    accumulate: 1, # a summation of each result type
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
