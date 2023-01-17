# == Schema Information
#
# Table name: survey_questions
#
#  id                   :integer          not null, primary key
#  format               :integer          default("select_one")
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

  before_save :set_position

  enum format: {
    select_one:  0,
    select_many: 1,
    scale:       2,
  }
  enum score_split_question: { # What does this mean?
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

  private

  def set_position
    self.position ||= begin
      last_pos = survey.survey_questions.maximum(:position) || -1
      last_pos + 1
    end
  end
end
