module CronParse
  module_function

  def next(cron)
    # current_user.timezone
    Time.use_zone("America/Denver") {
      Time.zone.at(Fugit::Cron.parse(cron).next_time.to_i)
    }
  end
end
