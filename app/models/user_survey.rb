# == Schema Information
#
# Table name: user_surveys
#
#  id         :integer          not null, primary key
#  token      :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  survey_id  :integer
#  user_id    :integer
#

class UserSurvey < ApplicationRecord
  belongs_to :user
  belongs_to :survey
  has_many :user_survey_responses

  before_save :set_token

  def results
    count_data = grouped_responses
    total = count_data.values.sum
    count_data.map do |survey_result_id, result_count|
      result = survey.survey_results.find(survey_result_id)
      # TODO: Don't grab the first one. Do conditional logic to find which description to show
      {
        name: result.name,
        description: result.survey_result_details.first.description,
        percentage: ((result_count / total.to_f) * 100).round,
      }
    end.sort_by { |data| -data[:percentage] }
  end

  def grouped_responses
    user_survey_responses
      .left_joins(survey_question_answer: :survey_question_answer_results)
      .group(:survey_result_id)
      .count
  end

  private

  def set_token
    self.token ||= loop do
      token = SecureRandom.hex(3)
      break token unless self.class.where(token: token).any?
    end
  end
end
