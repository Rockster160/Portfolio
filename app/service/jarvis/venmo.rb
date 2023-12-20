# Might be special/not an integration
class Jarvis::Venmo < Jarvis::Action
  def attempt
    # Should also convert "1 dollar" to "$1"
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    _, req, name, amount, note = parse_data

    if note.blank?
      return "Failed to Venmo- please provide a note to include in the request."
    end

    res = ::Oauth::VenmoApi.new(@user).charge_by_name(name, amount.to_f * (req.present? ? -1 : 1), note)

    Jarvis::Text.affirmative
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, @current_reserved_words)

    @rx.match_any_words?(@msg, :venmo)
    # Maybe other things like
    # send <name> $\d+
    # ask for <name> $\d+
    # request <name> $\d+
  end

  def parse_data
    @msg.squish.match(/venmo (request )?([\w' ]+) \$?(\d+(?:\.\d+)?) ?(?:for )?((?:.|\p{Emoji_Presentation}){0,})/iu).to_a
  end
end
