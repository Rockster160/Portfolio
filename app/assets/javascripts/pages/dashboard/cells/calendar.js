$(".ctr-dashboard").ready(function() {
  if (demo) { return }

  local_calendar_cell = Cell.register({
    title: "Calendar",
    text: "Loading...",
    x: 1,
    y: 3,
    h: 3,
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
})
