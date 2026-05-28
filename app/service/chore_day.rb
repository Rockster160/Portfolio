# Chore "day" boundary uses a 4am cutoff in the user's timezone — chores
# completed at 3am still count for the previous day. Centralising the logic
# keeps every completion/streak/hot-pick site agreeing on the same key.
class ChoreDay
  CUTOFF_HOURS = 4

  def self.current(user = nil, at: Time.current)
    zone = user_zone(user)
    zoned = at.in_time_zone(zone)
    (zoned - CUTOFF_HOURS.hours).to_date
  end

  def self.starts_at(day, user = nil)
    zone = user_zone(user)
    zone.local(day.year, day.month, day.day, CUTOFF_HOURS, 0, 0)
  end

  def self.ends_at(day, user = nil)
    starts_at(day + 1, user)
  end

  def self.range(day, user = nil)
    starts_at(day, user)...ends_at(day, user)
  end

  def self.user_zone(user)
    return Time.zone if user.blank?

    ::ActiveSupport::TimeZone[user.timezone] || Time.zone
  end
end
