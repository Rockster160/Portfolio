class FitnessBroadcast
  TIME_OFFSET = 4.hours # Base everything off of 4am
  # Five is a good day's applying, not a ceiling — see `tally`.
  APPLICATION_GOAL = 5

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
      (@days.first.beginning_of_day + TIME_OFFSET)..(@days.last.end_of_day + TIME_OFFSET)
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
      (date.beginning_of_day + TIME_OFFSET)..(date.end_of_day + TIME_OFFSET)
    }
  end

  def fitness_data
    [
      # pullups,
      days,
      wordle,
      drugs,
      animal_crossing,
      water,
      workout,
      teeth,
      shower,
      applications,
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
      "D-Amphetamine",
      "D-AmphetamineXR",
    ].map { |name| "name::\"#{name}\"" }.join(" OR ")
    row("💊", names, want)
  end

  def animal_crossing
    row("[hicon Animal Crossing Leaf]", "name::AnimalCrossing", need)
  end

  def water
    chore = @user.chores.find_by(name: "8oz Water")
    expected = need(chore&.target_count || 2)
    counts_by_day = (
      if chore
        ChoreCompletion.where(chore_id: chore.id, user: @user, day_key: @days).group(:day_key).count
      else
        {}
      end
    )

    "💧 " + dates("💧") { |date| colorize_count(counts_by_day[date] || 0, expected) }
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

  # Applications sent, off the tracker at /interviews rather than an event log:
  # the `applied` note is what jobhunt writes when a form actually submits, and
  # it is the same beat whether the robot sent it or he did.
  #
  # Counted from the NOTES and not from the applications themselves, because a
  # company already on the board gets the note without a new row — a second
  # go at somebody who turned him down in June would otherwise never be counted.
  def applications
    counts = Hash.new(0)
    notes = JobNote.applied.where(occurred_at: @range, job_application: @user.job_applications)
    notes.pluck(:occurred_at).each { |at| counts[perceived_day(at)] += 1 }

    "💼 " + dates("💼") { |date|
      colorize_count(counts[date], tally(APPLICATION_GOAL))
    }
  end

  # Which day a timestamp belongs to under the 4am rollover `allday` draws its
  # windows on, so a midnight application lands on the day it was sent up on.
  def perceived_day(at)
    (at.in_time_zone(@user.timezone) - TIME_OFFSET).to_date
  end

  def need(num=1)
    {
      green:  num..,
      orange: num >= 2 ? (1...num) : nil,
      red:    0,
      icons:  { ✓: num.., 𐄂: 0 },
    }.compact_blank
  end

  def want(num=1)
    {
      green: num..,
      grey:  ...num,
      icons: { ✓: num.., 𐄂: ...num },
    }.compact_blank
  end

  def bad(num=1)
    {
      green:  0,
      orange: num >= 2 ? (1...num) : nil,
      red:    num..,
      icons:  { ✓: 0, 𐄂: num },
    }.compact_blank
  end

  # The count itself, colored against a goal. `need` and `want` both swap in a
  # tick once the number is met, which reads identically at the goal and at
  # triple it — fine for a habit that is done or not, wrong for a row where
  # "how many" IS the question. No `compact_blank`: the empty `icons` is the
  # whole point of this one, and is exactly what that would throw away.
  def tally(num=1)
    { green: num.., orange: 1...num, red: 0, icons: {} }
  end

  def row(ico, q, expected)
    [
      ico.presence&.then { |i| "#{i} " },
      *dates(ico) { |date| status(date, q, expected) },
    ].inject(&:+)
  end

  def status(date, q, color_map)
    colorize_count(query(q, date).count, color_map)
  end

  def colorize_count(count, color_map)
    icon = count.zero? ? "-" : count
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
    events.query(q).where(timestamp: allday(date)).where(user: @user).order(timestamp: :asc)
  end

  def colorize(str, color_name)
    color = {
      green:  "#148F14",
      orange: "#FFA001",
      yellow: "#FFEE14",
      red:    "#F81414",
    }[color_name] || color_name

    "[color #{color}]#{str.to_s.rjust(3)}[/color]"
  end

  def dates(_ico="", &block)
    @days.then { |r| (r.first.to_date)..(r.last.to_date) }.map { |date|
      block.call(date).to_s.rjust(3)
    }.reverse.join(" ")
  end

  def broadcast
    ActionCable.server.broadcast(:fitness_channel, { fitness_data: fitness_data.join("\n") })
  end
end
