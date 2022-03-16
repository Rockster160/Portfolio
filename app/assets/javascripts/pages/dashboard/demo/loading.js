$(".ctr-dashboard").ready(function() {
  Cell.init({
    title: "Loading",
    flash: false,
    interval: 100,
    reloader: function(cell) {
      cell.data.percent = cell.data.percent || 0
      cell.data.percent = cell.data.percent + Math.random()
      if (cell.data.percent > 100) {
        cell.data.percent = cell.data.percent - 100
      }

      cell.lines([
        Text.progressBar(cell.data.percent),
        Text.progressBar(cell.data.percent, {
          post_text: Math.round(cell.data.percent) + "%",
          open_char: null,
          close_char: null,
          current_char: null,
          progress_char: "|"
        }),
      ])
    }
  })
})
