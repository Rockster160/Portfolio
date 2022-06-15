import { Time } from "./_time"

(function() {
  window.local_reminders_cell = Cell.register({
    title: "Reminders",
    text: "Loading...",
    refreshInterval: Time.hour(),
    wrap: true,
    flash: false,
    commands: {
      render: function(data) {
        this.lines(data)
        this.flash()
      },
    },
    reloader: function() {
      clearTimeout(window.local_data_timer)
      window.local_data_timer = setTimeout(function() { window.localDataChannel.request() }, 50)
    }
  })
})()
