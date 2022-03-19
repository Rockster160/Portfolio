$(".ctr-dashboard").ready(function() {
  if (demo) { return }

  Cell.init({
    title: "Notes",
    w: 2,
    x: 1,
    y: 2,
    reloader: function() {
      this.text(localStorage.getItem("notes"))
    },
    commands: {
      clear: function() {
        localStorage.removeItem("notes")
        this.text("")
      }
    },
    command: function(text) {
      var cell = this
      if (/^-\d+$/.test(text)) {
        var num = parseInt(text.match(/\d+/)[0])
        var lines = cell.text().split("\n")
        lines.splice(num-1, 1)
      } else {
        var lines = cell.text() ? cell.text().split("\n") : []
        lines.push(text)
      }

      var note = Text.numberedList(lines).join("\n")

      localStorage.setItem("notes", note)
      cell.text(note)
    }
  })
})
