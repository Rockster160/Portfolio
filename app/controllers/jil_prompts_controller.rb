class JilPromptsController < ApplicationController
  before_action :authorize_user
  before_action :set_prompt

  def update
    @prompt.update(response: params.dig(:prompt, :response))

    redirect_to @prompt
  end

  private

  def set_prompt
    @prompt = current_user.prompts.find_by(id: params[:id])

    return if @prompt.present?
    redirect_to login_path, alert: "You do not have permission to view this prompt."
  end
end
