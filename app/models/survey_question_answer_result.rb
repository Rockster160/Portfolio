# == Schema Information
#
# Table name: survey_question_answer_results
#
#  id                        :integer          not null, primary key
#  value                     :integer
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  survey_id                 :integer
#  survey_question_answer_id :integer
#  survey_question_id        :integer
#  survey_result_id          :integer
#

class SurveyQuestionAnswerResult < ApplicationRecord
  belongs_to :survey
  belongs_to :survey_question
  belongs_to :survey_question_answer
  belongs_to :survey_result
end
