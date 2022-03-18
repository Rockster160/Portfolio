$(".ctr-dashboard").ready(function() {
  if (demo) { return }

  local_calendar_cell = Cell.init({
    title: "Calendar",
    text: "Loading...",
    x: 1,
    y: 3,
    h: 3,
    flash: false,
    commands: {
      render: function(cell, data) {
        cell.lines(data)
        cell.flash()
      },
    },
    reloader: function(cell) {
      clearTimeout(local_data_timer)
      local_data_timer = setTimeout(function() { App.localData.request() }, 50)
    }
  })
})
