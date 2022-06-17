class AmazonEmailParser
  def self.parse(email)
    new(email).parse
  end

  def initialize(email)
    @email = email
  end

  def parse
    @doc = Nokogiri::HTML(@email.html_body)

    if @email.html_body.include?("Your package has been delivered!")
      save("[DELIVERED]")
    else
      date_str = arrival_date_str
      date = Date.parse(date_str) if date_str.present?
      save(date.to_s.presence || "[ERROR]")
    end
  rescue StandardError => e
    SlackNotifier.notify("Failed to parse Amazon:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>\n#{e.try(:message) || e.try(:body) || e.inspect}", channel: '#portfolio', username: 'Mail-Bot', icon_emoji: ':mailbox:')
  end

  def save(str)
    data_store = (DataStorage[:amazon_deliveries] || {}).with_indifferent_access
    order = data_store[order_id] || {}
    order[:delivery] = str
    data_store[order_id] = order
    DataStorage[:amazon_deliveries] = data_store

    ActionCable.server.broadcast "amz_updates_channel", data_store
  end

  def order_id
    @order_id ||= @email.html_body[/\#\d{3}-\d{7}-\d{7}/]
  end

  def arrival_date_str
    if @email.html_body.include?("your package will arrive")
      # shipment-tracking@amazon.com
      msg = @doc.at_css("tbody div:contains('your package will arrive')")
      msg ||= @doc.at_css("tbody div:contains('is arriving earlier than we previously expected')")

      msg&.ancestors("tbody")&.first&.css("td")&.last&.text&.squish
    elsif @email.html_body.include?("Arriving:")
      # auto-confirm@amazon.com
      @doc.at_css("span:contains('Arriving:')")&.parent&.at_css("b font")&.text&.squish
    elsif @email.html_body.include?("Now expected")
      # order-update@amazon.com
      @doc.at_css("span:contains('Now expected')")&.text.to_s[/Now expected \w+ \d+/].to_s[/\w+ \d+$/]
    else
      SlackNotifier.notify("Failed to parse Amazon:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", channel: '#portfolio', username: 'Mail-Bot', icon_emoji: ':mailbox:')
      ""
    end
  end
end
