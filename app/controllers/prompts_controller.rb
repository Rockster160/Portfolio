class PromptsController < ApplicationController
  before_action :authorize_user_or_guest
  before_action :set_prompt, except: :index
  after_action :repush_notifications

  def index
    @prompts = current_user.prompts.unanswered.order(created_at: :desc)
    redirect_to @prompts.first if @prompts.one?
  end

  def update
    data = params.dig(:prompt, :response)&.permit!.to_h
    @prompt.update(response: data)
    jil_trigger(:prompt, @prompt.with_jil_attrs(status: :complete))

    redirect_to jarvis_path
  end

  def destroy
    @prompt.destroy
    jil_trigger(:prompt, @prompt.with_jil_attrs(status: :skip))
    redirect_to prompts_path
  end

  private

  def repush_notifications
    return unless user_signed_in?

    ::WebPushNotifications.update_count(current_user)
  end

  def set_prompt
    @prompt = current_user.prompts.find_by(id: params[:id])

    return if @prompt.present?
    return store_and_login if guest_account?

    redirect_to prompts_path, alert: "You do not have permission to view this prompt."
  end
end
