# Everyday names for Amazon products, from their listing titles, for the
# deliveries on the dashboard: "Bike Phone Mount", not "Bike & Motorcycle Phone
# Mount - For iPhone 16 (15, Xr, SE, Max/Plus), Galaxy S22 or any Cell Phone".
# The person ordered it, so the name only has to remind them which thing it is.
#
# One call for a batch of titles. Each name lands in AmazonItemCatalog, so a
# product is named once however often it's ordered.
module AmazonFriendlyName
  module_function

  MODEL = "gpt-5.4-mini".freeze

  INSTRUCTIONS = <<~TEXT.freeze
    You name products for someone's list of deliveries. They placed the order, so each
    name only has to remind them which thing it is, the way they'd say it out loud.

    Give the thing itself in one to four words, Title Case: no brand, model number,
    size, count, color, or feature list. Keep a word that tells two of their orders
    apart, like a flavor or what it's for. Keep a brand only when the brand is the
    thing's everyday name, as with a drink.

    Examples of the right kind of name: "Strawberry Celsius", "Bowling Shoes",
    "Bike Gloves", "Bike Phone Mount", "Kitty Litter", "Zigbee Button".

    The titles are numbered. Answer with a JSON object, {"names": [...]}, holding one
    name per title in the same order.
  TEXT

  # One name per title, in order; nil where none came back, and all nil when
  # the call fails, so a caller always has its own fallback to reach for.
  def call(titles, user: User.me)
    titles = Array(titles).map(&:to_s)
    return [] if titles.empty?

    result = Buddy::GPT::Client.new(model: MODEL).stream(
      instructions: INSTRUCTIONS,
      input:        [{
        role:    :user,
        content: [{ type: :input_text, text: numbered(titles) }],
      }],
    )
    record_usage(result, user)
    names = result[:ok] ? parse(result[:text]) : []
    Array.new(titles.length) { |index| names[index] }
  rescue StandardError => e
    Rails.logger.warn("[AmazonFriendlyName] #{e.class}: #{e.message}")
    Array.new(titles.length)
  end

  def numbered(titles)
    titles.each_with_index.map { |title, index| "#{index + 1}. #{title}" }.join("\n")
  end

  def parse(text)
    json = text.to_s[/\{.*\}/m]
    return [] if json.nil?

    Array(JSON.parse(json)["names"]).map { |name| name.to_s.squish.presence }
  rescue JSON::ParserError
    []
  end

  def record_usage(result, user)
    BuddyUsage.record!(result, user: user, kind: :amazon_names)
  rescue StandardError => e
    Rails.logger.warn("[AmazonFriendlyName] usage record failed: #{e.class}: #{e.message}")
  end
end
