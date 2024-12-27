class FitnessBroadcast
  TIME_OFFSET = 4.hours # Base everything off of 4am

  def self.broadcast
    new.broadcast
  end

  def self.fitness_data
    new.fitness_data
  end

  def initialize
    @user = User.me
    @days = Time.use_zone(@user.timezone) {
      (6.days.ago.to_date)..(Time.current.to_date)
    }
    @range = Time.use_zone(@user.timezone) {
      (@days.first.beginning_of_day+TIME_OFFSET)..(@days.last.end_of_day+TIME_OFFSET)
    }
  end

  def events
    @events ||= @user.action_events.where(timestamp: @range)
  end

  def today
    @today ||= Time.current.in_time_zone(@user.timezone)
  end

  def allday(date)
    Time.use_zone(@user.timezone) {
      (date.beginning_of_day+TIME_OFFSET)..(date.end_of_day+TIME_OFFSET)
    }
  end

  def fitness_data
    [
      # pullups,
      days,
      wordle,
      drugs,
      treat,
      water,
      workout,
      teeth,
      shower,
      calories,
    ]
  end

  # def pullups
  #   pulls = @user.action_events.where(name: "Pullups").where("notes ~ '^\\d+$'")

  #   month_goal = 1_000
  #   current_yday = today.yday
  #   days_in_year = today.end_of_year.yday
  #   days_in_month = today.end_of_month.mday

  #   current_date = today.beginning_of_day...today.end_of_day
  #   current_month = today.beginning_of_month...today.end_of_month

  #   pullups_today = pulls.where(timestamp: current_date).sum("notes::integer")
  #   pullups_this_month = pulls.where(timestamp: current_month).sum("notes::integer")

  #   monthly_remaining = month_goal - pullups_this_month
  #   monthly_goal = (
  #     if days_in_month == today.mday
  #       monthly_remaining
  #     else
  #       ((month_goal - pullups_this_month) / (days_in_month - today.mday)).round(1)
  #     end
  #   )

  #   "#{pullups_today}t / #{monthly_remaining}r / #{monthly_goal}d"
  # end

  def days
    "   " + dates { |date| date.strftime("%a") }
  end

  def wordle
    row("📖", "name::Wordle", need)
  end

  def drugs
    names = [
      "Auvelity",
      "BupropionXL",
      "Buspirone",
      "Fluoxetine",
      "Vitamins",
      "Trintellix",
    ].map { |name| "name::#{name}" }.join(" OR ")
    row("💊", names, want)
  end

  def treat
    row("[img /can.png]", "name::Soda OR name::Treat", bad)
  end

  def water
    row("💧", "name::Water", need(2))
  end

  def workout
    row("🤸‍♂️", "name::Workout OR name::Z OR name::'Z*'", need)
  end

  def teeth
    row("🪥", "name::Teeth", need)
  end

  def shower
    row("🚿", "name::Shower", want)
  end

  def calories
    calorie_event_names = ["food", "soda", "drink", "alcohol", "treat", "snack", "workout", "z"]
    cal_query = calorie_event_names.map { |n| "name::#{n}" }.join(" OR ")
    "🔥 " + dates do |date|
      cal_events = query(cal_query, date)
      total = -1800
      cal_events.each do |event|
        calories = event.data&.dig("Calories").to_i
        calories = -100 if event.name == "Z"
        calories *= -1 if event.name == "Workout"
        total += calories
      end
      total < 0 ? colorize(:✓, :green) : colorize(:𐄂, :red)
    end
  end

  def need(num=1)
    {
      green: num..,
      orange: num >= 2 ? (1...num) : nil,
      red: 0,
      icons: { ✓: num.., 𐄂: 0 }
    }.compact_blank
  end

  def want(num=1)
    {
      green: num..,
      grey: ...num,
      icons: { ✓: num.., 𐄂: ...num }
    }.compact_blank
  end

  def bad(num=1)
    {
      green: 0,
      orange: num >= 2 ? (1...num) : nil,
      red: num..,
      icons: { ✓: 0, 𐄂: num }
    }.compact_blank
  end

  def row(ico, q, expected)
    ico.presence&.then { |i| "#{i} " } + dates(ico) do |date|
      status(date, q, expected)
    end
  end

  def status(date, q, color_map)
    count = query(q, date).count
    icon = count == 0 ? "-" : count
    color_map[:icons].each do |ico, range|
      icon = ico if range.is_a?(Integer) && count == range
      icon = ico if range.is_a?(Range) && count.in?(range)
    end

    color_name = color_map[:default] || :grey
    color_map.except(:icons).each do |col, range|
      next if col == :default
      color_name = col if range.is_a?(Integer) && count == range
      color_name = col if range.is_a?(Range) && count.in?(range)
    end

    colorize(icon, color_name)
  end

  def query(q, date)
    events.query(q).where(timestamp: allday(date))
  end

  def colorize(str, color_name)
    color = {
      green: "#148F14",
      orange: "#FFA001",
      yellow: "#FFEE14",
      red: "#F81414",
    }[color_name] || color_name

    "[color #{color}]#{str.to_s.rjust(3)}[/color]"
  end

  def dates(ico="", &block)
    @days.then { |r| (r.first.to_date)..(r.last.to_date) }.map { |date|
      block.call(date).to_s.rjust(3)
    }.reverse.join(" ")
  end

  def broadcast
    ActionCable.server.broadcast(:fitness_channel, { fitness_data: fitness_data.join("\n") })
  end
end
