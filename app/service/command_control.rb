class CommandControl
  include ActionView::Helpers::DateHelper

  def self.parse(msg)
    new(msg).run
  end

  def initialize(msg)
    @msg = msg
  end

  def run
    run_function if command?
  end

  private

  def run_function
    @msg.gsub!(/^\s*run /i, "")

    command = CommandProposal::Task.find_by("? ILIKE CONCAT(friendly_id, '%')", @msg)
    command ||= CommandProposal::Task.find_by("? ILIKE CONCAT(REGEXP_REPLACE(friendly_id, '[^a-z]', '', 'i'), '%')", @msg.gsub(/[^a-z]/i, ""))
    return "No command found." if command.nil?

    @msg.sub!(/#{command.name}/i, "")
    @msg.sub!(/send text/i, "")

    @msg, time = @msg.split(" at ").map(&:squish)

    if time.present?
      schedule = CommandProposal::Task.find_by(name: "Schedule Function")
      return "No 'Schedule Function' found." if schedule.blank?

      args = args_from_msg
      time = time_from_msg

      return "Sorry, I can't figure out what time that is." if time.nil?

      FunctionWorker.perform_at(time, command.friendly_id, args)
      "Sure, I'll run #{command.name} in #{distance_of_time_in_words(Time.current, time)} from now."
    else
      ::CommandProposal::Services::Runner.command(command.friendly_id, User.find(1), args_from_msg)&.result.presence || "No result"
    end
  end

  def command?
    @msg.squish.starts_with?(/run /i)
  end

  def args_from_msg
    args = {}
    delete = []

    arg_names = @msg.scan(/\w+\=/)
    @msg[/\w+\=.*/].to_s.split(/\w+\=/).each_with_index do |argv, idx|
      next if idx == 0

      arg_name = arg_names[idx-1]
      args[arg_name[0..-2]] = argv.squish
      delete << "#{arg_name}=#{argv}"
    end

    delete.each do |del|
      @msg.gsub!(del, "")
    end

    args
  end

  def time_from_msg
    Time.zone = "MST"
    Chronic.time_class = Time.zone
    Chronic.parse(@msg.gsub("at", "").squish)
  end
end
