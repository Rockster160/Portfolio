module ChatGPT
  module_function

  def last_ask = @last_ask
  def last_response = @last_response
  def last_chat_data = @last_chat_data

  def client
    @client ||= OpenAI::Client.new
  end

  def ask(str)
    @last_ask = str
    response = client.chat(
      parameters: {
        model: "gpt-3.5-turbo", # Required.
        messages: [{ role: "user", content: str }], # Required.
      }
    )
    @last_chat_data = response
    @last_response = response.dig("choices", 0, "message", "content")
  end

  def short_name_from_order(order_title)
    prompt = "I've ordered an item online. The title is much longer than I'd like it. " \
    "I know the item I ordered, but sometimes I order multiple items so I need some way to " \
    "identify this specific item and list it. Please remove all product details, "\
    "brand information, sizing data, and anything else that's generic. "\
    "Return only the item name in as few letters and characters as possible. "\
    "The title will be displayed in a list that only allows 20 characters:"

    ask("#{prompt} #{order_title}")&.then { |title|
      title.gsub!(/\d+/, "").squish if title.match?(/[\D\S]/)
      title.gsub!(/\bfilament\b/i, "Ink")
    }
  end

  def order_with_timestamp(email_text)
    now = Time.current.in_time_zone(User.timezone)
    res = ask(
      "Assuming today is #{now}, respond with nothing but the order id and the" \
      " expected delivery timestamp formatted in iso8601 from the following email:\n#{email_text}"
    )

    # "Order ID: 111-3842886-2135464\nExpected Delivery Timestamp: 2023-07-25T22:00:00-0600"
    [
      res.match(/(\d{3}-\d{7}-\d{7})/).to_a[1],
      res.match(/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}-\d{4})/).to_a[1],
    ]
    # ["111-3842886-2135464", "2023-07-25T22:00:00-0600"]
  end

  def calorie_check(item)
    prompt = (
      "Please respond only with the number of calories." \
      "Take your best guess at the calorie count for the provided dish." \
      "Assume a single serving unless there are multipliers in the text"
    )

    res = ask("#{prompt}: #{item}")
    res[/\d+/]
  end
end
