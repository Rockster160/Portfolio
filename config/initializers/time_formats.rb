# %Y - Year with century (can be negative, 4 digits at least)
# %C - year / 100 (rounded down such as 20 in 2009)
# %y - year % 100 (00..99)
# %m - Month of the year, zero-padded (01..12) %_m  blank-padded ( 1..12) %-m  no-padded (1..12)
# %B - The full month name (``January'') %^B  uppercased (``JANUARY'')
# %b - The abbreviated month name (``Jan'') %^b  uppercased (``JAN'')
# %h - Equivalent to %b
# %d - Day of the month, zero-padded (01..31) %-d  no-padded (1..31)
# %e - Day of the month, blank-padded ( 1..31)
# %j - Day of the year (001..366)
# %H - Hour of the day, 24-hour clock, zero-padded (00..23)
# %k - Hour of the day, 24-hour clock, blank-padded ( 0..23)
# %I - Hour of the day, 12-hour clock, zero-padded (01..12)
# %l - Hour of the day, 12-hour clock, blank-padded ( 1..12)
# %P - Meridian indicator, lowercase (``am'' or ``pm'')
# %p - Meridian indicator, uppercase (``AM'' or ``PM'')
# %M - Minute of the hour (00..59)
# %S - Second of the minute (00..60)
# %L - Millisecond of the second (000..999)
# %z - Time zone as hour and minute offset from UTC (e.g. +0900) %:z - hour and minute offset from UTC with a colon (e.g. +09:00) %::z - hour, minute and second offset from UTC (e.g. +09:00:00)
# %Z - Abbreviated time zone name or similar information.
# %A - The full weekday name (``Sunday'') %^A  uppercased (``SUNDAY'')
# %a - The abbreviated name (``Sun'') %^a  uppercased (``SUN'')
# %u - Day of the week (Monday is 1, 1..7)
# %w - Day of the week (Sunday is 0, 0..6)
# %U - Week number of the year. The week starts with Sunday. (00..53)
# %W - Week number of the year. The week starts with Monday. (00..53)
# %s - Number of seconds since 1970-01-01 00:00:00 UTC.

Time::DATE_FORMATS[:short] = "%-m/%-d/%y"
Time::DATE_FORMATS[:short_time] = "%-l:%M %p"
Time::DATE_FORMATS[:short_with_time] = "%-m/%-d/%y %-l:%M %p"
Time::DATE_FORMATS[:simple_with_time] = "%b %-d, %Y %-l:%M:%S %p"
Time::DATE_FORMATS[:quick_week_time] = "%a %b %-d, %-l:%M %p"
Time::DATE_FORMATS[:simple] = "%b %-d, %Y"
Time::DATE_FORMATS[:simple12_with_time] = "%b %-d, '%y %-l:%M%P"
Time::DATE_FORMATS[:time_with_simple12] = "%-l:%M %P %b %-d, '%y"
Time::DATE_FORMATS[:compact_week_month_time] = "%a %b %-d %-l:%M %p"
Time::DATE_FORMATS[:short_weekday_with_date] = "%a %b %-d, %Y %-l:%M %p"
Time::DATE_FORMATS[:short_day_month] = "%-d %b"
Time::DATE_FORMATS[:short_month_day] = "%b %-d"
Time::DATE_FORMATS[:month_day] = "%B %-d"
