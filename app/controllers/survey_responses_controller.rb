class SurveyResponsesController < ApplicationController
  skip_before_action :verify_authenticity_token

  def show
    @survey_response = UserSurvey.find_by!(token: params[:id])
    @survey = @survey_response.survey
  end

end
