module CustomLog
  module_function

  def self.log(txt)
    time = Time.current.in_time_zone(User.timezone).to_s
    time.gsub!(" -0700", " MST")
    File.open(Rails.root.join("custom_log.log"), "a+") { |f| f.puts "\e[90m[#{time}]\e[0m #{txt}" }
  end
end
