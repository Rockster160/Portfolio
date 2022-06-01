# == Schema Information
#
# Table name: survey_question_answers
#
#  id                 :integer          not null, primary key
#  position           :integer
#  text               :text
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  survey_id          :integer
#  survey_question_id :integer
#

class SurveyQuestionAnswer < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_question
  has_many :survey_question_answer_results, dependent: :destroy
  has_many :user_survey_responses, dependent: :destroy

  before_save :set_position

  private

  def set_position
    self.position ||= begin
      last_pos = survey_question.survey_question_answers.maximum(:position) || -1
      last_pos + 1
    end
  end
end
