class JilRunnerWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform(user_id)
    return if User.advisory_lock_exists?("jil_runner_#{user_id}")

    User.with_advisory_lock("jil_runner_#{user_id}", 5.seconds) {
      execute_continually(User.find(user_id))
    }
  end

  def execute_continually(user)
    loop do
      executed_any = false

      user.tasks.active.ordered.enabled.pending.each do |task|
        executed_any = true
        task.execute
      end

      # Execute all ScheduledTriggers that are ready
      user.scheduled_triggers.ready.order(:execute_at).each do |schedule|
        executed_any = true
        schedule.started!

        ::Jil.trigger_now(
          schedule.user, schedule.trigger,
          { timestamp: schedule.execute_at }.merge(schedule.data)
        )

        schedule.completed!
        ::Jil::Schedule.broadcast(schedule, :completed)
      end

      break unless executed_any
    end
  end
end
