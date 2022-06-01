(function() {
  window.local_calendar_cell = Cell.register({
    title: "Calendar",
    text: "Loading...",
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
