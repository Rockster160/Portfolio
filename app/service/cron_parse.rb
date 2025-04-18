module CronParse
  module_function

  def next(cron, user=nil)
    Time.use_zone((user || User).timezone) {
      # Do NOT use commas to split- commas are part of cron syntax, so should not be used for multiple crons
      cron.split(/\s*\|\s*/).filter_map { |cron_str|
        Fugit::Cron.parse(cron_str)&.next_time&.to_i&.then { |i| Time.zone.at(i) }
      }.min
    }
  rescue NoMethodError # parse returns `nil` if it fails, then `next_time` throws an error
    nil
  end
end
