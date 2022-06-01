class SurveyResponsesController < ApplicationController

  def show
    @survey_response = UserSurvey.find_by!(token: params[:id])
    @survey = @survey_response.survey
  end

end
