class FitnessBroadcast
  def self.broadcast
    new.broadcast
  end

  def self.fitness_data
    new.fitness_data
  end

  def initialize
    @user = User.me
    @range = Time.use_zone(@user.timezone) { 6.days.ago.beginning_of_day..Time.current.end_of_day }
  end

  def events
    @events ||= @user.action_events.where(timestamp: @range)
  end

  def today
    @today ||= Time.current.in_time_zone(@user.timezone)
  end

  def allday(date)
    Time.use_zone(@user.timezone) { date.beginning_of_day..date.end_of_day }
  end

  def fitness_data
    [
      pullups,
      days,
      wordle,
      drugs,
      treat,
      water,
      workout,
      teeth,
      shower,
    ]
  end

  def pullups
    pulls = @user.action_events.where(event_name: "Pullups").where("notes ~ '^\\d+$'")

    month_goal = 1_000
    current_yday = today.yday
    days_in_year = today.end_of_year.yday
    days_in_month = today.end_of_month.mday

    current_date = today.beginning_of_day...today.end_of_day
    current_month = today.beginning_of_month...today.end_of_month

    pullups_today = pulls.where(timestamp: current_date).sum("notes::integer")
    pullups_this_month = pulls.where(timestamp: current_month).sum("notes::integer")

    monthly_remaining = month_goal - pullups_this_month
    monthly_goal = (
      if days_in_month == today.mday
        monthly_remaining
      else
        ((month_goal - pullups_this_month) / (days_in_month - today.mday)).round(1)
      end
    )

    "#{pullups_today}t / #{monthly_remaining}r / #{monthly_goal}d"
  end

  def days
    "   " + dates { |date| date.strftime("%a") }
  end

  def wordle
    row("📖", "name::Wordle", need)
  end

  def drugs
    names = [
      "Buspirone",
      "Vitamins",
    ].map { |name| "name::#{name}" }
    row("💊", "OR(#{names})", want)
  end

  def treat
    row("[img /can.png]", "OR(name::Soda name::Treat)", bad)
  end

  def water
    row("💧", "name::Water", need(2))
  end

  def workout
    row("🤸‍♂️", "OR(name::Workout name::Z name::Z*)", need)
  end

  def teeth
    row("🪥", "name::Teeth", need)
  end

  def shower
    row("🚿", "name::Shower", want)
  end

  def need(num=1)
    {
      green: num..,
      orange: num >= 2 ? (1...num) : nil,
      red: 0,
      icons: { ✓: num, 𐄂: 0 }
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
    count = events.query(q).where(timestamp: allday(date)).count
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
    color = {
      green: "#148F14",
      orange: "#FFA001",
      yellow: "#FFEE14",
      red: "#F81414",
    }[color_name] || color_name

    "[color #{color}]#{icon.to_s.rjust(3)}[/color]"
  end

  def dates(ico="", &block)
    @range.then { |r| (r.first.to_date)..(r.last.to_date) }.map { |date|
      block.call(date).to_s.rjust(3)
    }.reverse.join(" ")
  end

  def broadcast
    ActionCable.server.broadcast(:fitness_channel, { fitness_data: fitness_data.join("\n") })
  end
end
