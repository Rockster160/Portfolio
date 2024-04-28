class AmazonEmailParserError < StandardError; end
class AmazonEmailParser
  include Memoizeable

  def self.parse(email)
    Time.use_zone(User.timezone) do
      new(email).parse
    end
  end

  memoize order_id: -> { @email.html_body[/\b\d{3}-\d{7}-\d{7}\b/] }

  def initialize(email)
    @email = email
  end

  def parse
    @doc = Nokogiri::HTML(@email.html_body)
    return Jarvis.cmd("Add Amazon Email no order id: #{@email.id}") if order_id.blank?

    if @email.html_body.include?("Your package has been delivered!")
      doall { |item| item.delivered = true }
    else
      parse_email
    end

    AmazonOrder.save
    AmazonOrder.broadcast
  rescue StandardError => e
    SlackNotifier.err(e, "Error parsing Amazon:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", username: 'Mail-Bot', icon_emoji: ':mailbox:')
  end

  def order_items
    @order_items ||= begin
      urls = @doc.to_s.scan(/\"https:\/\/www\.amazon\.com\/gp\/.*?\"/)

      item_ids = urls.filter_map { |url|
        next if url.include?("orderId%3D")

        full_url = url[1..-2]
        full_url[/www\.amazon\.com\%2Fdp\%2F([a-z0-9]+)\%2Fref/i, 1].presence
      }.uniq

      item_ids.map { |item_id|
        AmazonOrder.find_or_create(order_id, item_id).tap { |item|
          item.errors = [] # Clear errors since a new email came in
          item.email_ids << @email.id unless item.email_ids.include?(@email.id)
        }
      }
    end
  end

  def doall(&block)
    order_items.each { |item| block.call(item) }
  end

  def parse_email
    arrival_date.tap { |date|
      if date.nil?
        doall { |item| item.error!("Unable to parse date") }
      else
        doall { |item| item.delivery_date = date }
      end
    }
    arrival_time.tap { |time| doall { |item| item.time_range = time } } # might be `nil`
    doall { |item| item.name ||= shortened_name(item) }
  end

  def regex_words(*words)
    Regexp.new("\\b(?:#{words.join("|")})\\b")
  end

  memoize month_regex: -> {
    month_names = Date::MONTHNAMES.compact
    with_shorts = month_names.map { |day| [day, day.first(3)] }.flatten
    regex_words(with_shorts)
  }

  memoize wday_regex: -> {
    month_names = Date::DAYNAMES.compact
    with_shorts = month_names.map { |day| [day, day.first(3)] }.flatten
    regex_words(with_shorts)
  }

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
    month_regex
    month_regex
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

  def shortened_name(item)
    ChatGPT.short_name_from_order(full_name(item), item).to_s
  end

  def element(item) # the `tr` wrapping the image and name
    item.element ||= begin
      found = @doc.xpath("//a[contains(@href, '#{item.item_id}')]")
      found.filter_map { |ele| ele.ancestors("tr").first }.first
    end
  end

  def full_name(item)
    item.full_name ||= begin
      item.listed_name ||= element(item).at_css(".rio_black_href")&.text&.squish.to_s

      if item.listed_name.include?("...")
        retrieve_full_name(item).presence || item.listed_name
      else
        item.listed_name
      end
    end
  end

  def retrieve_full_name(item)
    res = ::RestClient.get(item.url)
    item_doc = Nokogiri::HTML(res.body)
    item_doc.title[/[^:]*? : (.*?) : [^:]*?/im, 1].tap { |name|
      error("Unable to parse title: [#{item.item_id}]:#{item_doc.title}") if name.blank?
    }.to_s
  rescue => e
    SlackNotifier.err(e, "Error pulling Amazon page:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", username: 'Mail-Bot', icon_emoji: ':mailbox:')
    ""
  end

  def error(msg="Failed to parse")
    Jarvis.cmd("Add Amazon Email #{msg}: #{@email.id}")
  end
end
