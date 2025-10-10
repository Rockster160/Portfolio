module SlackNotifier
  module_function

  def notify(message, channel: "#portfolio", username: "Portfolio-Bot", icon_emoji: ":blackmage:", attachments: [])
    return puts("\e[31mSlack: #{message}\e[0m") if Rails.env.test?

    SlackWorker.perform_async(message, channel, username, icon_emoji, attachments)
  end

  def err(exception, message="Error: ", channel: "#portfolio", username: "Portfolio-Bot", icon_emoji: ":blackmage:", attachments: [])
    SlackNotifier.notify(
      "#{message}\n*#{exception}*\n#{exception.message}\n" \
      "```#{format_exception(exception)}```",
    )
  end

  def format_exception(exception)
    focused = exception.backtrace.select { |l| l.include?("/app/") }
    focused.map { |line| line[/releases\/\d+(.*)/, 1] || line }.join("\n")
  end
end
