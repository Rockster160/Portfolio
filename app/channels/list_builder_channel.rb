class ListBuilderChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_channel"
  end
end
