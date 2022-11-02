class ListJsonChannel < ApplicationCable::Channel
  def subscribed
    stream_from "#{params[:channel_id]}_json_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end

  def receive(data)
    data = data.deep_symbolize_keys!
    list = List.find(params[:channel_id].gsub(/^list_/, ""))

    # TODO: Support updating order
    if data[:get].present?
      list.broadcast!
    elsif data[:swap].present?
      idx1, idx2 = data[:message].split("-").map { |n| n.to_i - 1 }
      ordered = list.list_items.order(sort_order: :desc).ids
      ordered[idx1], ordered[idx2] = ordered[idx2], ordered[idx1]

      list.list_items.with_deleted.update_all(sort_order: nil)
      ordered.reverse.each_with_index do |list_item_id, idx|
        list_item = list.list_items.with_deleted.find_by(id: list_item_id)
        list_item&.update(sort_order: idx, do_not_broadcast: true)
      end

      list.broadcast!
    elsif data[:move].present?
      idx1, idx2 = data[:message].split("^").map { |s| s.to_i.then { |n| n < 0 ? n : (n - 1) } }
      idx2 ||= 0
      ordered = list.list_items.order(sort_order: :desc).ids
      ordered.insert(idx2, ordered.delete_at(idx1))

      list.list_items.with_deleted.update_all(sort_order: nil)
      ordered.reverse.each_with_index do |list_item_id, idx|
        list_item = list.list_items.with_deleted.find_by(id: list_item_id)
        list_item&.update(sort_order: idx, do_not_broadcast: true)
      end

      list.broadcast!
    elsif data[:rename].present?
      idx, new_name = data[:message].split(" ", 2)
      ordered = list.list_items.order(sort_order: :desc).ids
      id = ordered[idx.to_i - 1]
      list.list_items.with_deleted.find(id).update(name: new_name)
    else
      list.update(data.slice(:add, :remove))
    end
  end
end
