class SlackNotifier

  def self.notify(message, channel='#portfolio', username='Portfolio-Bot', icon_emoji=':blackmage:', attachments=[])
    SlackWorker.perform_async(message, channel, username, icon_emoji, attachments)
  end

end
