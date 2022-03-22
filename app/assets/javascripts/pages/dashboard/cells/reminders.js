(function() {
  local_reminders_cell = Cell.register({
    title: "Reminders",
    text: "Loading...",
    x: 2,
    y: 3,
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
