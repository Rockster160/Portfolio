# Counting days in the head is where a daily countdown goes wrong: the model
# works out a number, finds a different one from an earlier day in the
# history, and tells them it got the count wrong before. Worked out here the
# number is exact, and the result says it is today's.
Buddy::Tools.register(
  name:        :count_days,
  summary:     "How many days until a date, or since one, counted from today.",
  description: <<~TXT,
    Count the days between today and a date - "how many days until the
    trip", "how long since I started", a daily countdown to a holiday. Pass
    the date as YYYY-MM-DD. The count comes straight back to you in this
    same turn, worked out from today in their own day, so say the number it
    gives rather than one of your own.
  TXT
  args:        {
    date: { type: :string, required: true, description: "The date to count to or from, YYYY-MM-DD" },
  },
  confirm:     ->(payload, _ctx) {
    date = Date.iso8601(payload[:date].to_s) rescue nil
    raise "#{payload[:date].inspect} isn't a date - pass YYYY-MM-DD" if date.nil?

    { summary: "Days to #{date.strftime("%-d %B %Y")}", resolved: { date: date.iso8601 } }
  },
  label:       ->(payload, _ctx) { "Days · #{payload[:date] || payload["date"]}" },
  auto:        true,
  answers:     true,
  execute:     ->(payload, ctx) {
    date  = Date.iso8601((payload[:date] || payload["date"]).to_s)
    today = Buddy::Day.today(ctx.user)
    days  = (date - today).to_i

    {
      today:   today.strftime("%A %-d %B %Y"),
      date:    date.strftime("%A %-d %B %Y"),
      days:    days.abs,
      counted: days.negative? ? :since : :until,
      how:     "This is the count for today. An earlier day's different number was right for " \
               "that day, so there is nothing to correct.",
    }
  },
)
