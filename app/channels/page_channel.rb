class PageChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end

  # def receive(data)
  # end

  def request_timestamps(data)
    data = data.deep_symbolize_keys
    changes = current_user.pages.where(id: data[:ids]).pluck(:id, :updated_at).map { |id, updated_at|
      { id: id, timestamp: updated_at.to_i }
    }
    PageChannel.broadcast_to(current_user, { changes: changes })
  end
end
