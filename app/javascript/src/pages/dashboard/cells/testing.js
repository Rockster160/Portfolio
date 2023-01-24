import { Text } from "../_text"
// import { Time } from "./_time"

(function() {
  Cell.register({
    title: "Testing",
    flash: false,
    data: {
      progress: 90,//(Math.random() * 100),
    },
    refreshInterval: 500,
    reloader: function() {
      this.data.progress = (this.data.progress + Math.random()) % 110
      this.text(
        Text.progressBar(this.data.progress)
      )
    },
    command: function(msg) {
      this.data.progress = (parseFloat(msg) || 0) - 0.5
    }
  })
})()
