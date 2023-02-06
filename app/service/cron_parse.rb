module CronParse
  module_function

  def next(cron)
    # current_user.timezone
    Time.use_zone("America/Denver") {
      cron.split(/\|\s*/).filter_map { |cron_str|
        Fugit::Cron.parse(cron_str)&.next_time&.to_i&.then { |i| Time.zone.at(i) }
      }.min
    }
  rescue NoMethodError # parse returns `nil` if it fails, then `next_time` throws an error
    nil
  end
end
