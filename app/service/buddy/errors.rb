module Buddy
  # Single funnel for all "silent-rescue" surfaces in the Buddy pipeline.
  # Every rescue in Buddy code that used to just `warn` and swallow now
  # calls `Buddy::Errors.report(section:, ...)`. The reporter:
  #
  #   1. Logs at ERROR level (not warn) with a full backtrace slice.
  #   2. Pings Slack asynchronously via SlackWorker (prod only), so Buddy
  #      failures surface the moment they happen rather than needing production
  #      logs grepped after the fact.
  #   3. Writes an ErrorReport row, which is the same failure in a form that
  #      can be counted and read back a day later. The ping interrupts; the row
  #      is what the Daily Audit reads.
  #   4. Re-raises in development so the failure is impossible to miss
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
        # Recorded FIRST, so the alert can carry a link to the row rather than
        # ending at a wall of text. `record!` answers nil instead of raising, so
        # a row that can't be written costs the LINK and never the alert - the
        # announcement is the part somebody is waiting on.
        row = ErrorReport.record!(
          section:   section,
          exception: exception,
          user:      user,
          extra:     extra,
          channel:   (SLACK_CHANNEL if announce?),
        )
        notify_slack(section, exception, user, extra, row) if announce?
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

      # Production with somewhere to send it. Asked before the row is written as
      # well as before the alert, so `channel` on the row says where this was
      # addressed rather than guessing.
      def announce?
        Rails.env.production? && defined?(SlackWorker) && SlackWorker::WEBHOOK_URL.present?
      end

      def log(section, exception, user, extra)
        lines = [
          "[Buddy::Errors] #{section} FAILED user=#{user&.id || 'nil'} #{extra.inspect}",
          "  #{exception.class}: #{exception.message}",
          *Array(exception.backtrace).first(10).map { |l| "  #{l}" },
        ]
        Rails.logger.error(lines.join("\n"))
      end

      # The row, when there is one, is the last line: everything above it is as
      # much as fits in an alert, and the link is where the rest of it lives.
      def notify_slack(section, exception, user, extra, row=nil)
        first_frame = Array(exception.backtrace).first(3).join("\n")
        message = <<~MSG
          *Buddy #{section} failed* for #{ErrorReport.who(user)}
          `#{exception.class}: #{exception.message}`
          ```
          #{first_frame}
          ```
          extra: `#{extra.inspect}`
          #{row&.slack_ref}
        MSG
        SlackWorker.perform_async(message.strip, SLACK_CHANNEL)
        SLACK_CHANNEL
      end
    end
  end
end
