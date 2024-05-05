class JilPromptsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_prompt, except: :index
  after_action :repush_notifications

  def index
    @prompts = current_user.prompts.unanswered.order(created_at: :desc)
    redirect_to @prompts.first if @prompts.one?
  end

  def update
    data = params.dig(:prompt, :response)&.permit!&.to_h || {}
    @prompt.update(response: data)
    @prompt.task&.execute(response: @prompt.response, params: @prompt.params)

    redirect_to jarvis_path
  end

  def destroy
    @prompt.destroy
    redirect_to jil_prompts_path
  end

  private

  def repush_notifications
    return unless user_signed_in?

    ::WebPushNotifications.update_count(current_user)
  end

  def set_prompt
    @prompt = current_user.prompts.find_by(id: params[:id])

    return if @prompt.present?
    # TODO: Extract this into a helper
    session[:forwarding_url] = request.original_url
    redirect_to login_path, alert: "You do not have permission to view this prompt."
  end
end
