# == Schema Information
#
# Table name: survey_questions
#
#  id                   :integer          not null, primary key
#  format               :integer
#  position             :integer
#  score_split_question :integer
#  text                 :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  survey_id            :integer
#

class SurveyQuestion < ApplicationRecord
  belongs_to :survey
  has_many :survey_question_answers
  has_many :survey_question_answer_results
  has_many :user_survey_responses

  enum format: {
    select_one:  0,
    select_many: 1,
    scale:       2,
  }
  enum score_split_question: {
    whole:   0,
    divided: 1,
  }

  def answers
    if survey.randomize_answers?
      survey_question_answers.shuffle
    else
      survey_question_answers.order(:position)
    end
  end
end
