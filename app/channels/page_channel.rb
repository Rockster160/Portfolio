class PageChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end

  # def receive(data)
  # end

  def request_timestamps(data)
    data = data.deep_symbolize_keys
    ids = data[:ids].select { |id| id.to_i.positive? }
    folder_names = data[:ids].select { |name| name.to_i.zero? }.map(&:parameterize)
    pages = current_user.pages.includes(:folder);nil
    folders = pages.where(folders: { parameterized_name: folder_names });nil
    changes = pages.where(id: ids).or(folders).map(&:to_packet)
    PageChannel.broadcast_to(current_user, { changes: changes })
  end
end
