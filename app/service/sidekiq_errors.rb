module SidekiqErrors
  module_function

  # The job that delivers alerts. Its own failures are recorded and never
  # announced, since announcing one queues another of it.
  QUIET_JOBS = %w[SlackWorker].freeze

  # Enough of a job's arguments to recognise which run it was.
  ARGS_LIMIT = 500

  # A job that raised, by the job's class so each one groups on its own,
  # through the same announcing as every other failure: the first is news, its
  # retries are repeats.
  def report(exception, context)
    job = context.to_h[:job] || {}
    klass = job["class"].presence || "unknown"
    section = "sidekiq:#{job["wrapped"].presence || klass}"
    extra = {
      jid:   job["jid"],
      retry: job["retry_count"],
      args:  job["args"].to_json.truncate(ARGS_LIMIT),
    }.compact

    if QUIET_JOBS.include?(klass)
      ErrorReport.record!(section: section, exception: exception, extra: extra, tag: :job)
    else
      SlackNotifier.notify(
        "Job #{klass} failed\n*#{exception.class}*\n#{exception.message}\n" \
        "```#{SlackNotifier.format_exception(exception)}```",
        exception: exception,
        section:   section,
        summary:   "Job #{klass} failed",
        extra:     extra,
        tag:       :job,
      )
    end
  rescue StandardError => e
    Rails.logger.error("[SidekiqErrors] couldn't report #{exception.class}: #{e.class}: #{e.message}")
  end
end
