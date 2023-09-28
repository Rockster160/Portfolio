class Jarvis::Bedtime < Jarvis::Action
  def self.reserved_words
    [:bed, :bedtime]
  end

  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    before_bed = []
    # Check if garage is open
    # Check if Tesla is charging
    # Check all apps are up
    if @user.default_list.list_items.any?
      before_bed << "Still todo:\n  * #{@user.default_list.ordered_items.pluck(:name).join("  \n")}"
    end
    Jarvis.ping(before_bed.join("\n")) if before_bed.any?

    return before_bed.any? ? "You may still need to close up shop, sir." : "Good night, sir."
  end

  def valid_words?
    return false if @rx.match_any_words?(@msg, @current_reserved_words)

    @rx.match_any_words?(@msg, *bedtime_commands)
  end

  def bedtime_commands
    [
      *self.class.reserved_words,
    ]
  end
end
