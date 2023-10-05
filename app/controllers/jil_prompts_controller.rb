class JilPromptsController < ApplicationController
  before_action :authorize_user
  before_action :set_prompt, except: :index

  def index
    @prompts = current_user.prompts.where(response: nil)
  end

  def update
    @prompt.update(response: params.dig(:prompt, :response))
    @prompt.task&.execute(response: @prompt.response, params: @prompt.params)

    redirect_to @prompt
  end

  private

  def set_prompt
    @prompt = current_user.prompts.find_by(id: params[:id])

    return if @prompt.present?
    redirect_to login_path, alert: "You do not have permission to view this prompt."
  end
end
