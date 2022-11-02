# Might be special/not an integration
class Jarvis::Venmo < Jarvis::Action
  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    _, req, name, amount, note = parse_data
    contact = @user.address_book.contact_by_name(name)
    from = contact&.phone || name

    return false if from.blank? || amount.blank?

    if note.blank?
      return "Failed to Venmo- please provide a note to include in the request."
    end

    ::Venmo.charge(from.gsub(/[^\d]/, "").last(10), amount.to_f * (req.present? ? -1 : 1), note)
    # Make sure the charge succeeds?

    if req.present?
      "Requesting $#{amount} from #{contact&.name || from}"
    else
      "Sending $#{amount} to #{contact&.name || from}"
    end
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, Jarvis.reserved_words - self.class.reserved_words)

    @rx.match_any_words?(@msg, :venmo)
    # Maybe other things like
    # send <name> $\d+
    # ask for <name> $\d+
    # request <name> $\d+
  end

  def parse_data
    # @msg.squish.match(/venmo (request )?([\w' ]+) \$?(\d+(?:\.\d+)?) ?(.*?)\.?/i).to_a
    # @msg.squish.match(/venmo (request )?([\w' ]+) \$?(\d+(?:\.\d+)?) ?((?:.|\p{Emoji_Presentation})*?)\.?/iu).to_a
    # @msg.squish.match(/\p{Emoji_Presentation}]/iu).to_a
    @msg.squish.match(/venmo (request )?([\w' ]+) \$?(\d+(?:\.\d+)?) ?((?:.|\p{Emoji_Presentation}){0,})/iu).to_a
  end
end
