class AmazonEmailParserError < StandardError; end
class AmazonEmailParser
  def self.parse(email)
    Time.use_zone(User.timezone) do
      new(email).parse
    end
  end

  # TODO: Detect if there are multiple items in the email and add each one as a different item!
  # TODO: If the name has an ellipsis, then open the page and pull from it instead.
  # If failed, fall back to the ellipsis name.

  # Test emails:
  # 3550 - different format (basic info card - Out for delivery "Today")
  # 3545 - different format (last info card - Order delayed "tomorrow by...")
  # 3465 - multiple items
  # 3458, 3455, 3454, 3450, 3393, 3392, 3347, 3346, 3344, 3342, 3338, 3336, 3335, 3334,
  # 3332, 3330, 3329, 3328, 3327, 3325, 3324, 3323, 3321, 3318, 3317, 3312, 3311, 3311, 3310, 3280,
  # 3275, 3274, 3271, 3270, 3264, 3261, 3258, 3255, 3254, 3253

  def initialize(email)
    @email = email
  end

  def parse
    @doc = Nokogiri::HTML(@email.html_body)
    return Jarvis.cmd("Add Amazon Email no order id: #{@email.id}") if order_id.blank?

    @order = AmazonOrder.find(order_id)
    @order.errors = [] # Clean previous errors

    if @email.html_body.include?("Your package has been delivered!")
      @order.delivered = true
    else
      parse_email
    end

    @order.email_ids << @email.id unless @order.email_ids.include?(@email.id)
    @order.save
    ActionCable.server.broadcast(:amz_updates_channel, AmazonOrder.serialize)
  rescue StandardError => e
    SlackNotifier.err(e, "Error parsing Amazon:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", username: 'Mail-Bot', icon_emoji: ':mailbox:')
  end

  def parse_email
    arrival_date.tap { |date|
      if date.nil?
        @order.error!("Unable to parse date")
      else
        @order.delivery_date = date
      end
    }
    @order.time_range = arrival_time # Might be `nil`
    @order.name ||= extract_name
  end

  def order_id
    @order_id ||= @email.html_body[/\b\d{3}-\d{7}-\d{7}\b/]
  end

  def regex_words(*words)
    Regexp.new("\\b(?:#{words.join("|")})\\b")
  end

  def month_regex
    month_names = Date::MONTHNAMES.compact
    with_shorts = month_names.map { |day| [day, day.first(3)] }.flatten
    regex_words(with_shorts)
  end

  def wday_regex
    month_names = Date::DAYNAMES.compact
    with_shorts = month_names.map { |day| [day, day.first(3)] }.flatten
    regex_words(with_shorts)
  end

  def future(date)
    loop { date.past? ? date += 1.week : (break date) }
  end

  def delayed_card_html
    @doc.at_css(".rio_last_card")&.inner_html.to_s
  end

  def basic_card_html
    @doc.at_css(".rio_card")&.inner_html.to_s
  end

  def info_card_html
    @doc.at_css(".rio_total_info_card")&.inner_html || fallback_html
  end

  def fallback_html
    if fallback_card_html["Order delayed"]
      return fallback_card_html
    elsif basic_card_html["Out for delivery"]
      return basic_card_html
    end

    "".tap { error("No info card") } # Always return at least an empty string, but notify if empty
  end

  def arrival_date
    months = month_regex
    wdays = wday_regex
    date_regexp = /(#{months}) \d{1,2}/
    date_str = info_card_html[date_regexp]
    return Date.today if date_str.nil? && info_card_html["Today"].present?
    return Date.tomorrow if date_str.nil? && info_card_html["tomorrow"].present?

    Date.parse(date_str).then { |date| future(date) }&.iso8601
  rescue
    nil
  end

  def arrival_time
    match = info_card_html.match(/(\d{1,2} ?[ap]\.?m\.?)\W*(\d{1,2} ?[ap]\.?m\.?)?/i)
    return unless match.present?

    _, start_range, end_range = match&.to_a
    meridian = (end_range || start_range).gsub(/[^a-z]/i, "")
    [start_range, end_range].compact.map { |time| time.gsub(/[^\d]/, "") }.join("-") + meridian
  end

  def extract_name
    @doc.at_css(".rio_black_href")&.text&.squish.to_s.delete(".").presence&.then { |title|
      ChatGPT.short_name_from_order(title)
    }
    # url = @doc.at_css(".rio_total_info_card").to_s[/\"https:\/\/www\.amazon\.com\/gp\/.*?\"/].to_s[1..-2]
    # /http%3A%2F%2Fwww.amazon.com%2Fdp%\w*%2Fref%3D\w*/
    # # https://www.amazon.com/dp/B01LP0V4JY/ref=pe_386300_440135490_TE_simp_item_image?th=1
    # # https://www.amazon.com/gp/r.html?C=1GDZONJ9HF37K&K=39KY183HTBH0A&M=urn:rtn:msg:20240312040919092d4cb729ab46ccbae7c3549b50p0na&R=U0YHAXB6XMBU&T=C&U=http%3A%2F%2Fwww.amazon.com%2Fdp%2FB01LP0V4JY%2Fref%3Dpe_386300_440135490_TE_simp_item_image&H=AZGK110P29ZNXGETGJLO6NST2D8A&ref_=pe_386300_440135490_TE_simp_item_image
    # # http%3A%2F%2Fwww.amazon.com%2Fdp%2FB01LP0V4JY%2Fref%3Dpe_386300_440135490_TE_simp_item_image&
    # return unless url.present?
    #
    # ::RestClient.get(url)
  end

  def error(msg="Failed to parse")
    Jarvis.cmd("Add Amazon Email #{msg}: #{@email.id}")
  end
end
