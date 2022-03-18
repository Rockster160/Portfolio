$(".ctr-dashboard").ready(function() {
  if (demo) { return }

  local_reminders_cell = Cell.init({
    title: "Reminders",
    text: "Loading...",
    x: 2,
    y: 3,
    interval: Time.minute(), // Only one local data class needs the interval
    commands: {
      render: function(cell, data) {
        cell.lines(data)
      },
    },
    reloader: function(cell) {
      clearTimeout(local_data_timer)
      local_data_timer = setTimeout(function() { App.localData.request() }, 50)
    }
  })
})
