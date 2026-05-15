class FireDueAgendaTriggersWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  def perform
    AgendaItem.trigger
      .incomplete
      .where(start_at: ..Time.current)
      .find_each do |item|
        fire(item)
      end
  end

  def fire(item)
    scope, data = item.parsed_trigger
    if scope.blank?
      item.update(completed_at: Time.current)
      return
    end

    if scope.to_s == "command"
      # `command:<text>` triggers run the text through Jarvis as if the user
      # had typed/said it — the same code path used for Alexa, SMS, terminal,
      # etc. Lets users schedule things like:
      #   command:"Remind me to wash dishes"
      words = extract_command_words(data)
      ::Jarvis.command(item.user, words) if words.present?
    else
      ::Jil.trigger(item.user, scope, data, auth: :agenda, auth_id: item.id)
    end

    item.update(completed_at: Time.current)
  rescue StandardError => e
    Rails.logger.error("[FireDueAgendaTriggersWorker] item=#{item.id} #{e.class}: #{e.message}")
    raise unless Rails.env.production?
  end

  # Pulls the words out of the parsed trigger data. The parser stores the
  # remainder of `command:"some text"` under the `:data` key (when there's a
  # single trailing segment); it also accepts nested forms by joining other
  # scalar values.
  def extract_command_words(data)
    return nil if data.blank?
    return data.to_s unless data.is_a?(::Hash)

    rest = data.except(:agenda_item)
    return rest[:data].to_s if rest[:data].is_a?(::String)

    rest.values.find { |v| v.is_a?(::String) }
  end
end
