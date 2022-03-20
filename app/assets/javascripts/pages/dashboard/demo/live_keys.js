$(".ctr-dashboard").ready(function() {

  Cell.init({
    title: "Live Keys",
    reloader: function() {
      var cell = this
    },
    focused: function(evt_key) {
      console.log(evt_key)
    }
  })
})
