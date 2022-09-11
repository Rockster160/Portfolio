import { Time } from "./_time"

(function() {
  window.local_reminders_cell = Cell.register({
    title: "Reminders",
    text: "Loading...",
    // We want timers to update every... Minute? But don't need to make a full server request
    refreshInterval: Time.minutes(5),
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
