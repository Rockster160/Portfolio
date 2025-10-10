class RescheduleItemsWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform
    ListItem.with_deleted.where.not(schedule_next: nil).where(schedule_next: ..DateTime.current).find_each do |list_item|
      list_item.deleted_at = nil
      list_item.set_next_occurrence
      list_item.save
    end
  end
end
