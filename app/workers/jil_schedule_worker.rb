class JilScheduleWorker
  include Sidekiq::Worker
  sidekiq_options retry: false

  def perform
    ::ScheduledTrigger.not_scheduled.upcoming_soon.find_each do |schedule|
      ::Jil::Schedule.add_job(schedule)
    end

    ::Task.enabled.pending.distinct.pluck(:user_id).each do |user_id|
      next if User.advisory_lock_exists?("jil_runner_#{user_id}")

      ::JilRunnerWorker.perform_async(user_id)
    end
  end
end
