module Buddy
  # Single funnel for all "silent-rescue" surfaces in the Buddy pipeline.
  # Every rescue in Buddy code that used to just `warn` and swallow now
  # calls `Buddy::Errors.report(section:, ...)`. The reporter:
  #
  #   1. Logs at ERROR level (not warn) with a full backtrace slice.
  #   2. Pings Slack asynchronously via SlackWorker (prod only). Rocco
  #      sees Buddy failures the moment they happen, no need to grep
  #      production logs after the fact.
  #   3. Re-raises in development so the failure is impossible to miss
  #      during local iteration.
  #
  # Reporting itself never raises - a hiccup in Slack delivery cannot
  # take down a Buddy turn.
  module Errors
    module_function

    SLACK_CHANNEL = "#zygy-alerts".freeze

    def report(section:, exception:, user: nil, extra: {})
      # Log + Slack wrapped in their own rescue: reporting a failure
      # must never take down the caller. The original exception is
      # already handled by whatever rescue invoked us; we just wanted
      # the visibility.
      begin
        log(section, exception, user, extra)
        notify_slack(section, exception, user, extra) if Rails.env.production?
      rescue
        nil
      end

      # Re-raise ONLY in development, and only after the above block.
      # A rescue wrapping the raise would swallow our own re-raise,
      # defeating the point of dev-mode loudness.
      raise exception if Rails.env.development?
    end

    class << self
      private

      def log(section, exception, user, extra)
        lines = [
          "[Buddy::Errors] #{section} FAILED user=#{user&.id || 'nil'} #{extra.inspect}",
          "  #{exception.class}: #{exception.message}",
          *Array(exception.backtrace).first(10).map { |l| "  #{l}" },
        ]
        Rails.logger.error(lines.join("\n"))
      end

      def notify_slack(section, exception, user, extra)
        return unless defined?(SlackWorker) && SlackWorker::WEBHOOK_URL.present?

        first_frame = Array(exception.backtrace).first(3).join("\n")
        message = <<~MSG
          *Buddy #{section} failed* (user=#{user&.id || 'nil'})
          `#{exception.class}: #{exception.message}`
          ```
          #{first_frame}
          ```
          extra: `#{extra.inspect}`
        MSG
        SlackWorker.perform_async(message, SLACK_CHANNEL)
      end
    end
  end
end
