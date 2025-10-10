class Jarvis::List < Jarvis::Action
  def attempt
    return unless valid_words?
    return if @user.blank?

    List.find_and_modify(@user, @msg).presence || true
  end

  def valid_words?
    return true if @rx.match_any_words?(@msg, :add, :remove)

    list_names = @user.lists.pluck(:name).map { |name| name.gsub(/[^a-z0-9 ]/i, "") }
    @rx.match_any_words?(@msg, list_names)
  end
end
