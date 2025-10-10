# Might be special/not an integration
class Jarvis::Venmo < Jarvis::Action
  def attempt
    # Should also convert "1 dollar" to "$1"
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    data = parse_data

    return "Failed to Venmo- unable to parse name from message." if data[:name].blank?
    return "Failed to Venmo- please provide a note to include in the request." if data[:note].blank?
    return "Failed to Venmo- unsure of amount to send." if data[:amount].blank?

    ::Oauth::VenmoApi.new(@user).charge_by_name(
      data[:name],
      data[:amount].to_f * (data[:request] ? -1 : 1), data[:note]
    )
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, @current_reserved_words)

    @rx.match_any_words?(@msg, :venmo)
    # Maybe other things like
    # send <name> $\d+
    # ask for <name> $\d+
    # request <name> $\d+
  end

  def token
    @token ||= (1..).lazy.each { |i| break "|" * i if @msg.exclude?("|" * i) }
  end

  def pull(msg, regex)
    match = msg.match(regex).to_a
    return if match.empty?

    msg.sub!(regex, token).squish! # Replace with the token so we can keep sections split
    match[1].presence || match[0].presence # First group or entire match string
  end

  def parse_data
    msg = @msg.dup.squish
    pull(msg, /venmo/i)
    amount = pull(msg, /(?:of )?\$? ?([0-9]+(?:\.[0-9]{1,2})?)/i).to_f
    request = pull(msg, /\b(request|ask)(?:ing)?(?: for)?(?: the)?\b/i)
    name = pull(msg, /\b(?:from|to) (\w+)/i)
    name ||= pull(msg, /\b(?:send|give?|pay|shoot)(?:ing)? ?(?:over)? (\w+)/i)
    name ||= pull(msg, /\b(\w+)/i) # First word if no other prefixes
    note = msg.split(token).last.to_s.sub(/\.*$/, "").sub(/^ *for( the)? +/, "").squish

    { request: !!request, name: name, amount: amount, note: note }
  end
end
