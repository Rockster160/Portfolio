# == Schema Information
#
# Table name: survey_results
#
#  id         :integer          not null, primary key
#  name       :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  survey_id  :integer
#

class SurveyResult < ApplicationRecord
  belongs_to :survey
  has_many :survey_result_details
  has_many :survey_question_answer_results
end
