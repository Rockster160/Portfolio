class ScheduledEventsWorker
  include Sidekiq::Worker
  sidekiq_options(
    lock: :while_executing,
    lock_args_method: ->(args) { [:fifo] },
    lock_timeout: nil,
    on_conflict: :reschedule
  )

  def perform(args={})
    args = JSON.parse(args) if args.is_a?(String)
    events = ::DataStorage[:scheduled_events] || []

    events += Array.wrap(args["add"])
    jids_to_remove = Array.wrap(args["remove"])

    # ::Sidekiq::ScheduledSet.new.map(&:jid)
    # ::JarvisWorker.perform_at(1.hour.from_now, 1, "Do something")
    scheduled_jids = ::Sidekiq::ScheduledSet.new.filter_map { |job|
      jids_to_remove.include?(job.jid) ? job.delete : (job.klass == "JarvisWorker" && job.jid )
    }
    events = events.select { |evt| evt["jid"].in?(scheduled_jids) && !evt["jid"].in?(jids_to_remove) }

    ::DataStorage[:scheduled_events] = events
    ::BroadcastUpcomingWorker.perform_async
  end
end
