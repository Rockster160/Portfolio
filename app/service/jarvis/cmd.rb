class Jarvis::Cmd < Jarvis::Action
  def attempt
    return unless valid_words?
    raise Jarvis::Error.not_allowed unless @user&.admin?

    return "Sorry, couldn't find a function called #{@args}." if @cmd.blank?

    CommandRunner.run(@user, @cmd, @args).presence || true
  end

  def valid_words?
    simple_words = @msg.downcase.squish
    tasks = ::CommandProposal::Task.where.not("REGEXP_REPLACE(COALESCE(friendly_id, ''), '[^a-z]', '', 'i') = ''")
    tasks = tasks.where(session_type: :function)

    return false unless tasks.any?

    command = tasks.find_by(uuid: simple_words)
    command ||= tasks.find_by("? ILIKE CONCAT('%', friendly_id, '%""')", simple_words)
    command ||= tasks.find_by("? ILIKE CONCAT('%', REGEXP_REPLACE(friendly_id, '[^a-z]', '', 'i'), '%')", simple_words.gsub(/[^a-z]/i, ""))

    return false unless command.present?

    without_name = @msg.gsub(Regexp.new("\\b(#{command.friendly_id.gsub("_", "\.\?")})\\b", :i), "")
    without_fn = without_name.squish.gsub(/^(fn|run|function)\b ?(fn|run|function)?/i, "")

    @cmd = command
    @args = without_fn.squish
    true
  end
end
