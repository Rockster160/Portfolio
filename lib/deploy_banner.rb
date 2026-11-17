# The line a deploy leaves in custom.log: a gold rule exactly WIDTH columns
# wide with the deploy's time and what shipped centered in it, so scrolling
# back through the requests shows where each release begins.
#
# Plain Ruby on purpose - Capistrano builds it, outside the app.
module DeployBanner
  module_function

  WIDTH = 74
  RULE = "━".freeze
  # The rule never shrinks below this on either side, so the line still reads
  # as a divider with the longest subject.
  MIN_RULE = 2
  SEPARATOR = " · ".freeze
  ELLIPSIS = "…".freeze

  GOLD = "\e[38;2;218;165;32m".freeze
  BOLD = "\e[1;97m".freeze
  DIM = "\e[90m".freeze
  RESET = "\e[0m".freeze

  def line(time:, subject:)
    stamp = time.strftime("%b %-d %-l:%M%P")
    room = WIDTH - (MIN_RULE * 2) - 2 - stamp.length - SEPARATOR.length
    subject = shorten(subject.to_s.strip, room)

    text_width = stamp.length + SEPARATOR.length + subject.length + 2
    left = (WIDTH - text_width) / 2
    right = WIDTH - text_width - left

    rule_left = "#{GOLD}#{RULE * left} "
    rule_right = "#{GOLD} #{RULE * right}#{RESET}"
    "#{rule_left}#{BOLD}#{stamp}#{RESET}#{DIM}#{SEPARATOR}#{RESET}#{subject}#{rule_right}"
  end

  # What a person would call the change: a PR merge goes by its title and
  # number, a merge of master into itself by the last real commit under it,
  # and anything else by its own first line.
  def subject(message, last_change: nil)
    first, *rest = message.to_s.strip.lines.map(&:strip)
    pull = first.to_s[/\AMerge pull request (#\d+)/, 1]
    title = rest.find { |line| !line.empty? }

    return "#{pull} #{title}" if pull && title
    return last_change.to_s.strip if first.to_s.start_with?("Merge ") && last_change.to_s.strip != ""

    first.to_s
  end

  def shorten(text, room)
    return text if text.length <= room

    cut = text[0, room - ELLIPSIS.length + 1]
    # Ends on a whole word when there is one to end on.
    cut = cut.include?(" ") ? cut.sub(/\s+\S*\z/, "") : cut.chop
    "#{cut.rstrip}#{ELLIPSIS}"
  end
end
