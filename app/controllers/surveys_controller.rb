class SurveysController < ApplicationController
  before_action :authorize_user

  def index
    @surveys = Survey.all
  end

  def show
    @survey = Survey.includes(survey_questions: :survey_question_answers).find_by(slug: params[:id])
  end

  def update
    @survey = Survey.find(params[:id])

    sesh = current_user.user_surveys.create(survey_id: @survey.id)
    params.dig(:survey, :questions).each do |question_id, answer_id|
      sesh.user_survey_responses.create(
        user: current_user,
        survey: @survey,
        survey_question_id: question_id,
        survey_question_answer_id: answer_id,
      )
    end

    redirect_to survey_response_path(sesh.token)
  end

end
