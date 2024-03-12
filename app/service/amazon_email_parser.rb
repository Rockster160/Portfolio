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

    if @email.html_body.include?("Your package has been delivered!")
      save("[DELIVERED]")
    else
      save
    end
  rescue StandardError => e
    SlackNotifier.err(e, "Error parsing Amazon:\n<#{Rails.application.routes.url_helpers.email_url(id: @email.id)}|Click here to view.>", username: 'Mail-Bot', icon_emoji: ':mailbox:')
  end

  def save(timestamp_str=nil)
    data_store = (DataStorage[:amazon_deliveries] || {}).with_indifferent_access
    order = data_store[order_id] || {}
    order[:delivery] = timestamp_str || arrival_date
    extract_name&.tap { |name| order[:name] = name } if order[:name].blank?
    data_store[order_id] = order
    DataStorage[:amazon_deliveries] = data_store

    ActionCable.server.broadcast(:amz_updates_channel, data_store)
    order
  end

  def order_id
    @order_id ||= @email.html_body[/\b\d{3}-\d{7}-\d{7}\b/]
  end

  def arrival_date
    months = Regexp.new(Date::MONTHNAMES.compact.join("|"))
    date_regexp = /(#{months}) \d{1,2}/
    date_str = @email.html_body[date_regexp] || arrival_date_str
    date = @email.html_body["Today"] if date_str.nil?
    date || Date.parse(date_str)&.iso8601
  rescue
    "[ERROR]"
  end

  def extract_name
    @doc.at_css(".rio_black_href")&.text&.squish.to_s.delete(".").presence
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
