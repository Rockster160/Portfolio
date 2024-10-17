import { Text } from "../_text"

(function() {
  window.local_calendar_cell = Cell.register({
    title: "Calendar",
    text: "\n\n\n" + Text.center(Text.red("== [FIXME] ==")),
    wrap: true,
    flash: false,
    commands: {
      render: function(data) {
        this.lines(data)
        this.flash()
      },
    },
    reloader: function() {
      // clearTimeout(window.local_data_timer)
      // window.local_data_timer = setTimeout(function() { window.localDataChannel.request() }, 50)
    }
  })
})()

// CALENDAR_COLORS = {
//   grey:     "#42464A",
//   yellow:   "#CBCB4D",
//   paleblue: "#9FE1E7",
//   lblue:    "#3D94F6",
//   magenta:  "#B55088",
//   pink:     "#EE9BB5",
//   green:    "#65DB39",
//   pine:     "#3E8948",
//   orange:   "#FF9500",
//   brown:    "#A2845D",
//   red:      "#FF0000",
// }

// today_str = Time.current.in_time_zone("Mountain Time (US & Canada)").strftime("%b %-d, %Y:")
// # calendar_data = LocalDataCalendarParser.call
//
// mapped_colors = {
//   "rocco11nicholls@gmail.com"   => :lblue,
//   "rocco.nicholls@workwave.com" => :orange,
//   "rocco@oneclaimsolution.com"  => :pine,
//   "Janaya"                      => :pink,
//   "Workout"                     => :brown,
// }
//
// calendar_data.map { |date_str, events|
//   lines = [date_str, "[hr]"]
//   events.sort_by { |evt| evt[:start_time] || Time.current.beginning_of_day }.each do |event|
//     next if event[:name].in?(ignore_list)
//     if event[:time_str].present?
//       name = event[:name] || event[:uid]
//       color = mapped_colors[event[:calendar]]
//       name = colorize(name, color) if color.present?
//       lines.push("• #{name}")
//       lines.push("    #{colorize(event[:time_str], :yellow)}")
//     else
//       lines.push("• #{colorize(event[:name] || event[:uid], :magenta)}")
//     end
//     next if event[:location].blank?
//     next if event[:location].include?("zoom.us")
//     next if event[:location].include?("meet.google")
//     next if event[:location].match?(/webinar/i) # GoToWebinar
//
//     lines.push("    #{colorize(event[:location].strip, :grey)}")
//   end
//   lines.push("") # Empty line between days
// }.flatten
// end
