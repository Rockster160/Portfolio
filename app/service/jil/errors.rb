# A task that raised, through the same recording and announcing as every other
# failure, so it reaches /system/errors and the Daily Audit. A failed run is
# otherwise only a status on its execution, which nothing reads.
module Jil::Errors
  module_function

  def report(exception, task: nil, user: nil, execution: nil, line: nil)
    name    = task ? "Task #{task.name} (##{task.id})" : "Jil code"
    section = task ? "jil:task:#{task.id}" : "jil"
    at      = " at `#{line}`" if line.present?

    SlackNotifier.notify(
      "#{name} failed#{at}\n*#{exception.class}*\n#{exception.message}\n" \
      "```#{SlackNotifier.format_exception(exception)}```",
      exception: exception,
      section:   section,
      summary:   "#{name} failed",
      user:      user,
      extra:     { execution_id: execution&.id, line: line.presence&.to_s }.compact,
      tag:       :task,
    )
  rescue StandardError => e
    Rails.logger.error("[Jil::Errors] couldn't report #{exception.class}: #{e.class}: #{e.message}")
  end
end
