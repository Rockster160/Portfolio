class JilChannel < ApplicationCable::Channel
  def subscribed
    if current_user.jarvis_task_ids.include?(params[:id].to_i)
      stream_from "jil_#{params[:id]}_channel"
    end
  end
end
