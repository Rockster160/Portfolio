if (demo) {
  Cell.init({
    title: "Loading",
    interval: Time.second() / 10,
    reloader: function(cell) {
      cell.data.percent = cell.data.percent || 0
      cell.data.percent = cell.data.percent + random()
      if (cell.data.percent > 100) {
        cell.data.percent = cell.data.percent - 100
      }
      cell.lines([
        Text.progressBar(cell.data.percent),
        Text.progressBar(0),
        Text.progressBar(1.5),
        Text.progressBar(5),
        Text.progressBar(50),
        Text.progressBar(97),
        Text.progressBar(98.9),
        Text.progressBar(100),
      ])
    }
  })
}
