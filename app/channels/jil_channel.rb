class JilChannel < ApplicationCable::Channel
  def subscribed
    found = current_user.jarvis_tasks.where(uuid: params[:id]).any?
    stream_from "jil_#{params[:id]}_channel" if found
  end
end
