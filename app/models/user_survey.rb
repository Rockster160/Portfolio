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
  has_many :user_survey_responses, dependent: :destroy

  before_save :set_token

  def results
    survey.accumulate? ? accumulate_results : aggregate_results
  end

  def aggregate_results
    count_data = grouped_responses.count
    total = count_data.values.sum
    count_data.map do |survey_result_id, result_count|
      result = survey.survey_results.find(survey_result_id)
      {
        name: result.name,
        # TODO: Don't grab the first one. Do conditional logic to find which description to show
        description: result.survey_result_details.first&.description,
        percentage: ((result_count / total.to_f) * 100).round,
      }
    end.sort_by { |data| -data[:percentage] }
  end

  def accumulate_results
    grouped_responses.sum(:value).map { |survey_result_id, result_count|
      result = survey.survey_results.find(survey_result_id)
      {
        name: result.name,
        # TODO: Don't grab the first one. Do conditional logic to find which description to show
        description: result.survey_result_details.first&.description,
        amount: result_count,
      }
    }.sort_by { |data| -data[:amount] }
  end

  private

  def grouped_responses
    user_survey_responses
      .left_joins(survey_question_answer: :survey_question_answer_results)
      .group(:survey_result_id)
  end

  def set_token
    self.token ||= loop do
      token = SecureRandom.hex(3)
      break token unless self.class.where(token: token).any?
    end
  end
end
