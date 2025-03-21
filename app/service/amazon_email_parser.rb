# email = @email = Email.find(26542)
# @doc = Nokogiri::HTML(@email.html_body); nil
# def order_id; @order_id ||= @email.html_body[/\b\d{3}-\d{7}-\d{7}\b/]; end
# def month_regex; @month_regex ||= /\b(?:January|Jan|February|Feb|March|Mar|April|Apr|May|May|June|Jun|July|Jul|August|Aug|September|Sep|October|Oct|November|Nov|December|Dec)\b/; end
# def wday_regex; @wday_regex ||= /\b(?:Sunday|Sun|Monday|Mon|Tuesday|Tue|Wednesday|Wed|Thursday|Thu|Friday|Fri|Saturday|Sat)\b/; end

# Rack::Utils.parse_nested_query(URI.parse(url).query)

# Collect URLS from a bunch of ids, return all of the urls, pull out the good ones.
# Check if `www.amazon.com%2Fdp%2FB09VNT8WN2` only happens and happens for ALL goods
class AmazonEmailParserError < StandardError; end
class AmazonEmailParser
  include ::Memoizeable

  def self.parse(email)
    Time.use_zone(User.timezone) do
      new(email).parse
    end
  end

  memoize(:order_id) { @email.html_body[/\b\d{3}-\d{7}-\d{7}\b/] }

  def initialize(email)
    @email = email
  end

  def parse
    @changed = false
    @doc = Nokogiri::HTML(@email.html_body)
    return Jarvis.cmd("Add Amazon Email no order id: #{@email.id}") if order_id.blank?

    if @email.html_body.include?("Your package has been delivered!")
      doall(:order) { |item| item.delivered = true }
    else
      parse_email
    end

    AmazonOrder.save
    AmazonOrder.broadcast
    @changed
  rescue StandardError => e
    SlackNotifier.err(e, "Error parsing Amazon:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", username: 'Mail-Bot', icon_emoji: ':mailbox:')
    false
  end

  def order_items
    @order_items ||= begin
      AmazonOrder.by_order(order_id).tap { |items|
        items.each do |item|
          @changed = true
          item.errors = [] # Clear errors since a new email came in
          item.email_ids << @email.id unless item.email_ids.include?(@email.id)
        end
      }
    end
  end

  def email_items
    @email_items ||= begin
      # urls = @doc.to_s.scan(/\"https:\/\/www\.amazon\.com\/gp\/.*?\"/)
      urls = @doc.to_s.split(/keep shopping for/i, 2).first.scan(/\"(https:\/\/www\.amazon\.com\/gp\/.*?)\"/).flatten

      item_ids = urls.filter_map { |url|
        next if url.include?("orderId%3D")
        next unless url.include?("U=%2Fdp")

        full_url = url[1..-2]
        full_url[/\%2Fdp\%2F([a-z0-9]+)/i, 1].presence# && full_url
      }.uniq.presence
      item_ids ||= [order_id]

      item_ids.map { |item_id|
        AmazonOrder.find_or_create(order_id, item_id).tap { |item|
          @changed = true
          item.errors = [] # Clear errors since a new email came in
          item.email_ids << @email.id unless item.email_ids.include?(@email.id)
        }
      }
    end
  end

  def doall(scope, &block)
    items = scope == :email ? email_items : order_items
    items.each { |item| block.call(item) }
  end

  def parse_email
    doall(:email) { |item|
      arrival_date(item).tap { |date|
        if date.nil?
          item.error!("Unable to parse date")
        else
          item.delivery_date = date.iso8601.encode("UTF-8")
        end
      }
      item.time_range = arrival_time(item) # might be `nil`
      item.name ||= shortened_name(item)
    }
  end

  def regex_words(*words)
    Regexp.new("\\b(?:#{words.join("|")})\\b")
  end

  memoize(:month_regex) {
    month_names = Date::MONTHNAMES.compact
    with_shorts = month_names.map { |day| [day, day.first(3)] }.flatten
    regex_words(with_shorts)
  }

  memoize(:wday_regex) {
    month_names = Date::DAYNAMES.compact
    with_shorts = month_names.map { |day| [day, day.first(3)] }.flatten
    regex_words(with_shorts)
  }

  def future(date)
    loop { date.past? ? date += 1.week : (break date) }
  end

  def element(item) # the `tr` wrapping the image and name
    @elements ||= {}
    @elements[item.item_id] ||= begin
      found = @doc.xpath("//a[contains(@href, '#{item.item_id}')]")
      found.filter_map { |ele| ele.ancestors("tr").first }.first
    end
  end

  def section(item) # the `table` wrapping the whole section (not just the items)
    @sections ||= {}
    @sections[item.item_id] ||= begin
      element(item)&.ancestors("table")&.each_cons(2) { |table_a, table_b|
        break table_a if table_b && table_b["class"] == "rio_body"
      }
    end
  end

  def arrival_date(item)
    table_html = section(item)&.inner_html
    return item.error!("No info card") if table_html.blank?

    months = month_regex
    wdays = wday_regex
    date_regexp = /(#{months}) \d{1,2}/
    date_str = table_html[date_regexp]
    return Date.today if date_str.nil? && table_html[/\btoday\b/i].present?
    return Date.tomorrow if date_str.nil? && table_html[/\btomorrow\b/i].present?

    date_str ||= table_html[/Arriving (#{wdays})/, 1]
    return Date.parse(date_str).then { |date| future(date) } if date_str.present?

    arrival_ele = @doc.at_xpath("//*[contains(text(), 'Your package will arrive by')]")
    arrival_text = arrival_ele&.ancestors("tr")&.first&.at_css(".rio_15_heavy_black")&.text
    return Date.parse(arrival_text).then { |date| future(date) } if arrival_text.present?
  rescue
    nil
  end

  def arrival_time(item)
    table_html = section(item)&.inner_html
    return item.error!("No info card") if table_html.blank?

    match = table_html.match(/(\d{1,2} ?[ap]\.?m\.?)\W*(\d{1,2} ?[ap]\.?m\.?)?/i)
    return unless match.present?

    _, start_range, end_range = match&.to_a
    meridian = (end_range || start_range).gsub(/[^a-z]/i, "")
    [start_range, end_range].compact.map { |time| time.gsub(/[^\d]/, "") }.join("-") + meridian
  end

  def shortened_name(item)
    ChatGPT.short_name_from_order(full_name(item), item).to_s
  end

  def full_name(item)
    item.full_name ||= begin
      item.listed_name ||= @email.subject[/^[^\"]*\"(.*?)\"[^\"]*$/, 1]
      item.listed_name ||= element(item).at_css(".rio_black_href")&.text&.squish.to_s
      count = @email.subject[/(\d+ ?x) ?\"/, 1]

      if item.listed_name.include?("...")
        [
          count,
          retrieve_full_name(item).presence || item.listed_name
        ].filter_map(&:presence).join(" ")
      else
        [count, item.listed_name].filter_map(&:presence).join(" ")
      end
    end
  end

  def retrieve_full_name(item)
    res = ::RestClient.get(item.url)
    item_doc = Nokogiri::HTML(res.body)
    name = item_doc.title[/(?:[^:]*? : |Amazon.com: )(.*?) : [^:]*?/im, 1]
    return name unless name.blank?

    name = item_doc.title.split(": Amazon.com").first
    error("Unable to parse title: [#{item.item_id}]:#{item_doc.title}") if name.blank?

    name.to_s
  rescue => e
    # Amazon occasionally does Captcha checks, which ends with this being a 500.
    # Don't report these, just return nothing and move on.
    # SlackNotifier.err(e, "Error pulling Amazon page:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", username: 'Mail-Bot', icon_emoji: ':mailbox:')
  end

  def error(msg="Failed to parse")
    Jarvis.say("Add Amazon Email #{msg}: #{@email.id}")
  end
end
