require "English"

module SlackNotifier
  module_function

  # A Slack ping sent while an exception is being HANDLED is a failure report,
  # whatever its wording - so it gets an ErrorReport row as well as a channel.
  #
  # `$ERROR_INFO` - `$!` - is what draws that line, and it draws it without
  # every caller having to say which kind of ping it is sending. It holds the
  # exception for the whole of a rescue, including the frames the rescue calls
  # into, and it is back to nil the moment the rescue ends. So the dozen
  # `notify` calls that live in rescues are all recorded, and the informational
  # ones - mail landing, an SMS arriving, a retry announcing itself - are not in
  # a rescue and stay out of the record.
  #
  # `user:` is the other half of it. A failure is worth very little without
  # saying who it happened for, so every caller with a user in hand passes one.
  def notify(
    message,
    channel: "#portfolio",
    username: "Portfolio-Bot",
    icon_emoji: ":blackmage:",
    attachments: [],
    user: nil,
    exception: $ERROR_INFO)
    # Recorded first, so the alert can end at a link to the whole row instead of
    # at whatever fitted in a message - and `record!` answers nil rather than
    # raising, so a row that can't be written costs the link and never the
    # alert.
    row = (record_failure(message, exception, user, channel) if exception)
    message = "#{message}\n#{trailer(user, row)}" if exception

    return puts("\e[31mSlack: #{message}\e[0m") if Rails.env.test?

    SlackWorker.perform_async(message, channel, username, icon_emoji, attachments)
  end

  def err(exception, message="Error: ", channel: "#portfolio", username: "Portfolio-Bot", icon_emoji: ":blackmage:", attachments: [], user: nil)
    SlackNotifier.notify(
      "#{message}\n*#{exception}*\n#{exception.message}\n" \
      "```#{format_exception(exception)}```",
      exception: exception,
      user:      user,
    )
  end

  # Who it happened for, and where the rest of it is. One line at the end, so
  # the message above it still reads the way whoever wrote it meant.
  #
  # The NAME does not depend on the row: an alert that can't say who a failure
  # happened for is most of the way to useless, and that must not be what a
  # failed insert costs. Only the link is the row's to give.
  def trailer(user, row)
    [ErrorReport.who(user), row&.slack_ref].compact.join(" · ").prepend("— ")
  end

  def record_failure(message, exception, user, channel)
    ErrorReport.record!(
      section:   caller_section,
      exception: exception,
      message:   message,
      user:      user,
      channel:   channel,
    )
  end

  def format_exception(exception)
    focused = exception.backtrace.select { |l| l.include?("/app/") }
    focused.map { |line| line[/releases\/\d+(.*)/, 1] || line }.join("\n")
  end

  # Taken from this file rather than from Rails.root, so a deploy running out of
  # a release directory still recognises its own frames.
  APP_ROOT = File.expand_path("../..", __dir__).freeze

  # Who was reporting, in the form a person reads a report in: the file and the
  # line, rather than the top of a backtrace that belongs to whatever raised.
  # Gem frames are passed over - a callback or a middleware sitting between the
  # rescue and here is not the thing that reported.
  def caller_section
    frame = caller_locations.find { |loc|
      loc.path != __FILE__ && loc.path.start_with?(APP_ROOT) && loc.path.exclude?("/vendor/")
    }
    frame.nil? ? "slack" : "#{File.basename(frame.path, ".rb")}:#{frame.lineno}"
  end
end
