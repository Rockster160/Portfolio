class JilRunnerWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform(user_id)
    return if User.advisory_lock_exists?("jil_runner_#{user_id}")

    User.with_advisory_lock("jil_runner_#{user_id}", 10.seconds) {
      execute_continually(User.find(user_id))
    }
  end

  def execute_continually(user)
    loop do
      executed_any = false

      user.tasks.active.ordered.enabled.pending.each do |task|
        executed_any = true
        task.execute(auth: :cron)
      end

      # Execute all ScheduledTriggers that are ready
      user.scheduled_triggers.ready.order(:execute_at).each do |schedule|
        executed_any = true
        schedule.started!

        # A trigger can carry a check answered HERE, at fire time, rather than
        # having been decided when it was scheduled - see ScheduleCondition.
        # `started!` then `completed!` with no `Jil.trigger` between them is
        # deliberate: the row's whole lifecycle still runs, so a skipped trigger
        # is a finished one rather than a stuck one, and nothing downstream has
        # to learn a third state.
        if schedule.condition_met?
          ::Jil.trigger(
            schedule.user, schedule.trigger,
            { timestamp: schedule.execute_at }.merge(schedule.data),
            auth: schedule.auth_type || :trigger, auth_id: schedule.auth_type_id
          )
        else
          Rails.logger.info(
            "[JilRunner] skipped trigger ##{schedule.id} - #{ScheduleCondition.describe(schedule.condition)}",
          )
          ScheduleCondition.announce_skip!(
            user:         schedule.user,
            conversation: schedule.buddy_conversation,
            condition:    schedule.condition,
            subject:      schedule.name.presence || schedule.trigger,
          )
        end

        schedule.completed!
        ::Jil::Schedule.broadcast(schedule, :completed)
      end

      break unless executed_any
    end
  end
end
