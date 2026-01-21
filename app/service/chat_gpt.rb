module ChatGPT
  module_function

  def last_ask = @last_ask
  def last_response = @last_response
  def last_chat_data = @last_chat_data

  def client
    @client ||= ::OpenAI::Client.new(log_errors: true)
  end

  def ask(str)
    @last_ask = str
    response = client.chat(
      parameters: {
        model:    "gpt-3.5-turbo", # Required.
        messages: [{ role: "user", content: str }], # Required.
      },
    )
    @last_chat_data = response
    @last_response = response.dig("choices", 0, "message", "content")
  end

  def generate_image(prompt)
    puts " > Generating icon for '#{item}'..."
    begin
      resp = client.images.generate(
        parameters: {
          model:  "dall-e-3",
          prompt: "#{prompt}\n\n#{item}",
          n:      1, # number of images to generate
          size:   "1024x1024",
        },
      )
      url = resp.dig("data", 0, "url").tap { sleep 0.5 } # Give the image a moment to save the image
    rescue Faraday::BadRequestError => e
      show_exc(e)
      raise
    end
  end

  def short_name_from_order(order_title, _item=nil) # item for stubbing in specs
    prompt = "I've ordered an item online. The title is much longer than I'd like it. " \
             "I know the item I ordered, but sometimes I order multiple items so I need some way to " \
             "identify this specific item and list it. Please remove all product and brand information, " \
             "sizing data, colors, and any other modifiers that describe the item but not the name itself. " \
             "Assume I already know the item so I don't need a lot of info, just the most basic item name." \
             "Return only the item name in as few letters and characters as possible. " \
             "The title will be displayed in a list that only allows 20 characters:"

    ask("#{prompt} #{order_title}")&.then { |title|
      # Maybe remove numbers and their attached words?
      # 4-Way, 1.75mm, etc...
      # Nah, because we still want things like x4
      title.gsub!(/\bfilament\b/i, "Ink")
      title.squish
    }
  end

  def order_with_timestamp(email_text)
    now = Time.current.in_time_zone(User.timezone)
    res = ask(
      "Assuming today is #{now}, respond with nothing but the order id and the " \
      "expected delivery timestamp formatted in iso8601 from the following email:\n#{email_text}",
    )

    # "Order ID: 111-3842886-2135464\nExpected Delivery Timestamp: 2023-07-25T22:00:00-0600"
    [
      res.match(/(\d{3}-\d{7}-\d{7})/).to_a[1],
      res.match(/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}-\d{4})/).to_a[1],
    ]
    # ["111-3842886-2135464", "2023-07-25T22:00:00-0600"]
  end

  def calorie_explain(item, color: false)
    prompt = (
      "Take your best guess at the calorie count for the provided dish." \
        "Take your time and research online, especially when given a restaurant." \
        "Assume a single serving unless there are multipliers in the text" \
        "and explain each portion that adds into the final result."
    )

    ask("#{prompt}\n\n> #{item}").then { |res|
      color ? res.gsub(/\b([\d+,])\b/, "\e[94m\\1\e[0m") : res
    }
  end

  # TODO: Use the magic format to require that it only returns a number
  def calorie_check(item)
    prompt = (
      "Please respond only with the number of calories." \
        "Take your best guess at the calorie count for the provided dish." \
        "Assume a single serving unless there are multipliers in the text"
    )

    res = ask("#{prompt}: #{item}")
    res[/\d+/]
  end

  def generate_sd_icon(item)
    tmp = "/Users/zoro/code/Portfolio/tmp/"

    prompt = "Simple, minimal, easily distinguishable, square icon for StreamDeck action button: "
    url = generate_image("#{prompt}\n\n#{item}")

    filename = item.parameterize.tr("-", "_")
    raw_filepath = "#{tmp}#{filename}-raw.png"
    URI.open(url) do |img|
      File.binwrite(raw_filepath, img.read)
    end

    magick_opts = [
      "-fuzz 20%",
      "-trim +repage",
    ].join(" ")
    clean_filepath = "#{tmp}#{filename}.png"
    `magick #{raw_filepath} #{magick_opts} #{clean_filepath}`
    # File.delete(raw_filepath) if File.exist?(raw_filepath)
    `open #{raw_filepath}`
    `open #{clean_filepath}`
    clean_filepath
  end
end
# 1. pick up the top‑left pixel colour
# bg=$(magick soda_can_edges.png -format "%[pixel:p{0,0}]" info:)
# # 2. make that bg transparent, then trim
# magick soda_can_edges.png \
#   -alpha set \
#   -fuzz 10% \
#   -fill none \
#   -floodfill +0+0 "$bg" \
#   -trim +repage \
#   soda_can_inner.png

# magick /Users/zoro/Downloads/soda_can_edges.png -fuzz 20% -trim +repage /Users/zoro/Downloads/soda_can_clean.png
