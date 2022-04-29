# == Schema Information
#
# Table name: user_survey_responses
#
#  id                        :integer          not null, primary key
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  survey_id                 :integer
#  survey_question_answer_id :integer
#  survey_question_id        :integer
#  user_id                   :integer
#  user_survey_id            :integer
#

class UserSurveyResponse < ApplicationRecord
  belongs_to :user
  belongs_to :survey
  belongs_to :user_survey
  belongs_to :survey_question
  belongs_to :survey_question_answer
end
