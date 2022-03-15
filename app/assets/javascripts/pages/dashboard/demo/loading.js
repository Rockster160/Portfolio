$(".ctr-dashboard").ready(function() {
  Cell.init({
    title: "Loading",
    flash: false,
    interval: Time.second() / 10,
    reloader: function(cell) {
      cell.data.percent = cell.data.percent || 0
      cell.data.percent = cell.data.percent + random()
      if (cell.data.percent > 100) {
        cell.data.percent = cell.data.percent - 100
      }

      cell.lines([
        Text.progressBar(cell.data.percent, { post_text: Math.round(cell.data.percent) + "%", open_char: null, close_char: null, progress_char: "|", current_char: "" }),
        Text.progressBar(0),
        Text.progressBar(1.5),
        Text.progressBar(5, { open_char: null }),
        Text.progressBar(50),
        Text.progressBar(97),
        Text.progressBar(98.9),
        Text.progressBar(100),
        Text.progressBar(47, { post_text: "47%" }),
      ])
    }
  })
})
