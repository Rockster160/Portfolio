class CommandControl
  include ActionView::Helpers::DateHelper

  def self.parse(msg)
    new(msg).run
  end

  def initialize(msg)
    @msg = msg
  end

  def run
    run_function if function?
  end

  private

  def run_function
    @msg.gsub!(/^\s*run /i, "")

    function = Function.find_by("? ILIKE CONCAT(title, '%')", @msg)
    return "No function found." if function.nil?

    @msg.sub!(/#{function.title}/i, "")

    msg, time = @msg.split(" at ").map(&:squish)

    if time.present?
      schedule = Function.find_by(title: "Schedule Function")
      return "No 'Schedule Function' found." if schedule.blank?

      args = args_from_msg
      time = time_from_msg

      return "Sorry, I can't figure out what time that is." if time.nil?

      FunctionWorker.perform_at(time, function.id, args)
      "Sure, I'll run #{function.title} in #{distance_of_time_in_words(Time.current, time)} from now."
    else
      RunFunction.run(function.id, args_from_msg)
    end
  end

  def function?
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
