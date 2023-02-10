class SlackNotifier

  def self.notify(message, channel: '#portfolio', username: 'Portfolio-Bot', icon_emoji: ':blackmage:', attachments: [])
    SlackWorker.perform_async(message, channel, username, icon_emoji, attachments)
  end

  def self.err(exception, message="Error: ", channel: '#portfolio', username: 'Portfolio-Bot', icon_emoji: ':blackmage:', attachments: [])
    SlackNotifier.notify(
      "#{message}\n*#{exception}*\n#{exception.message}\n" \
      "```#{exception.backtrace.select { |l| l.include?("/app/") }.reverse.join("\n")}```"
    )
  end

end
