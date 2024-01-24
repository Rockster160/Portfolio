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
    prompt = "In one or two words but less than 20 characters, summarize the following:"

    ask("#{prompt} #{order_title}")
  end

  def order_with_timestamp(email_text)
    now = Time.current.in_time_zone(User.timezone)
    res = ask(
      "Assuming today is #{now}, respond with nothing but the order id and the" \
      " expected delivery timestamp formatted in iso8601 from the following email: #{email_text}"
    )

    # "Order ID: 111-3842886-2135464\nExpected Delivery Timestamp: 2023-07-25T22:00:00-0600"
    [
      res.match(/Order ID: ([\d\-]+)/).to_a[1],
      res.match(/Expected Delivery Timestamp: (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}-\d{4})/).to_a[1],
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
    
  end
end
