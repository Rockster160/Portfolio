class AmazonEmailParserError < StandardError; end
class AmazonEmailParser
  def self.parse(email)
    new(email).parse
  end

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

  def info_card_html
    @doc.at_css(".rio_total_info_card")&.inner_html || "".tap {
      Jarvis.cmd("Add Amazon Email no info card: #{@email.id}")
    }
  end

  def arrival_date
    months = month_regex
    wdays = wday_regex
    date_regexp = /(#{months}) \d{1,2}/
    date_str = info_card_html[date_regexp]
    return Date.today if date_str.nil? && info_card_html["Today"].present?

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
end
