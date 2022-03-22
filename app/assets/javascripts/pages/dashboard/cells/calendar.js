(function() {
  local_calendar_cell = Cell.register({
    title: "Calendar",
    text: "Loading...",
    flash: false,
    commands: {
      render: function(data) {
        this.lines(data)
        this.flash()
      },
    },
    reloader: function() {
      clearTimeout(local_data_timer)
      local_data_timer = setTimeout(function() { App.localData.request() }, 50)
    }
  })
})()
