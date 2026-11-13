# Everyday names for Amazon products, from their listing titles, for the
# deliveries on the dashboard: "Bike Phone Mount", not "Bike & Motorcycle Phone
# Mount - For iPhone 16 (15, Xr, SE, Max/Plus), Galaxy S22 or any Cell Phone".
# The person ordered it, so the name only has to remind them which thing it is.
#
# One call for a batch of titles. Each name lands in AmazonItemCatalog, so a
# product is named once however often it's ordered. Names the person typed
# themselves go along as examples, which is how their own words for things
# ("Bike" for a motorcycle anything) reach the model.
module AmazonFriendlyName
  module_function

  MODEL = "gpt-5.4-mini".freeze
  # Longest name the dashboard is given. A longer one is a title, not a label.
  MAX = 25
  # Typed names sent along as examples; the newest, since the catalog keeps
  # them in the order they were set.
  EXAMPLES = 40

  INSTRUCTIONS = <<~TEXT.freeze
    You name products for someone's list of deliveries. They placed the order, so each
    name only has to remind them which thing it is, the way they'd say it out loud.

    Give the thing itself in one to four words and at most 25 characters, Title Case:
    no brand, model number, size, count, color, or feature list. Keep a word that
    tells two of their orders apart, like a flavor or what it's for. Keep a brand
    only when the brand is the thing's everyday name, as with a drink.

    Examples of the right kind of name: "Strawberry Celsius", "Bowling Shoes",
    "Bike Gloves", "Bike Phone Mount", "Kitty Litter", "Zigbee Button".

    The thing itself matters most: when the title leads with a brand and a list of
    features, find the noun it is actually selling. Use their words over the
    title's. They say "Bike" for anything motorcycle or bicycle, and the names
    they've typed for earlier orders, when given, show more of their words.

    The titles are numbered. Answer with a JSON object, {"names": [...]}, holding one
    name per title in the same order.
  TEXT

  # One name per title, in order. A title with no usable name back is asked
  # once more on its own; nil where that fails too, so the caller can leave
  # it for the next read rather than store a bad one.
  def call(titles, user: User.me)
    titles = Array(titles).map(&:to_s)
    names = ask(titles, user)
    missing = names.each_index.select { |index| names[index].nil? }
    return names if missing.empty?

    again = ask(titles.values_at(*missing), user)
    missing.zip(again).each { |index, name| names[index] = name }
    names
  end

  def ask(titles, user)
    return [] if titles.empty?

    result = Buddy::GPT::Client.new(model: MODEL).stream(
      instructions: INSTRUCTIONS,
      input:        [{
        role:    :user,
        content: [{ type: :input_text, text: prompt(titles) }],
      }],
    )
    record_usage(result, user)
    names = result[:ok] ? parse(result[:text]) : []
    Array.new(titles.length) { |index| names[index] }
  rescue StandardError => e
    Rails.logger.warn("[AmazonFriendlyName] #{e.class}: #{e.message}")
    Array.new(titles.length)
  end

  def prompt(titles)
    numbered = titles.each_with_index.map { |title, index| "#{index + 1}. #{title}" }
    typed = typed_examples
    return numbered.join("\n") if typed.empty?

    ["Names they typed for earlier orders:", *typed, "", "Titles:", *numbered].join("\n")
  end

  def typed_examples
    entries = AmazonItemCatalog.all.values.select { |entry|
      entry[:source].to_s == "typed" && entry[:name].present?
    }
    entries.last(EXAMPLES).map { |entry|
      title = entry[:full_name].presence || entry[:listed_name].presence
      title ? "#{entry[:name]} (for: #{title.truncate(80)})" : entry[:name].to_s
    }
  end

  def parse(text)
    json = text.to_s[/\{.*\}/m]
    return [] if json.nil?

    Array(JSON.parse(json)["names"]).map { |name| name.to_s.squish.presence if label?(name) }
  rescue JSON::ParserError
    []
  end

  # Whether a name is short enough to be a label at all.
  def label?(name)
    name = name.to_s.squish
    name.present? && name.length <= MAX && !name.end_with?("…")
  end

  # Whether a name is only words lifted from the title, as the old cut-down
  # names are ("JUESHITUO Magnetic"). A name of the person's own has a word of
  # theirs in it ("Bike Gloves" for INBIKE Motorcycle Gloves).
  def from_title?(name, title)
    title_words = words(title)
    return false if title_words.empty?

    (words(name) - title_words).empty?
  end

  def words(text)
    text.to_s.downcase.scan(/[[:alnum:]]+/)
  end

  def record_usage(result, user)
    BuddyUsage.record!(result, user: user, kind: :amazon_names)
  rescue StandardError => e
    Rails.logger.warn("[AmazonFriendlyName] usage record failed: #{e.class}: #{e.message}")
  end
end
