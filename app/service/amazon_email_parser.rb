module AmazonEmailParser
  def initialize(email)
    @email = email

    parse
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
  end

  def save(str)
    data_store = DataStorage[:amazon_deliveries] || {}
    data_store[order_id] = str
    DataStorage[:amazon_deliveries] = hash

    # broadcast
    # https://www.amazon.com/gp/your-account/order-details?orderID=111-6868123-4188211
  end

  def order_id
    @email.html_body[/\#\d{3}-\d{7}-\d{7}/]
  end

  def arrival_date_str
    if @email.html_body.include?("your package will arrive")
      # shipment-tracking@amazon.com
      @doc.at_css("tbody div:contains('your package will arrive')")
        .ancestors("tbody")
        .first
        .css("td")
        .last
        .text
        .squish
    elsif @email.html_body.include?("Arriving:")
      # auto-confirm@amazon.com
      @doc.at_css("span:contains('Arriving:')").parent.at_css("b font").text.squish
    elsif @email.html_body.include?("Now expected")
      # order-update@amazon.com
      @doc.at_css("span:contains('Now expected')").text[/Now expected \w+ \d+/][/\w+ \d+$/]
    else
      SlackNotifier.notify("Failed to parse Amazon:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", channel: '#portfolio', username: 'Mail-Bot', icon_emoji: ':mailbox:')
      ""
    end
  end
end
