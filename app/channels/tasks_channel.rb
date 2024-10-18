class TasksChannel < ApplicationCable::Channel
  def subscribed
    if params[:id] == "new" || current_user.tasks.exists?(uuid: params[:id])
      stream_from "tasks:#{current_user.id}_#{params[:id]}_channel"
    else
      reject
    end
  end

  def self.send_to(user, uuid, data)
    broadcast_to("#{user.id}_#{uuid}_channel", data)
  end
end
