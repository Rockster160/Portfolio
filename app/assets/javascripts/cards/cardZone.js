$('.ctr-cards').ready(function() {
  setTimeout(function() {
    addZone = function(opts) {
      var $playingField = $('.playing-field')
      var opts = opts || {}
      var color = opts.color || "red"
      var coord = opts.coord || { top: $playingField.offset().top + $playingField.height() / 2, left: $playingField.offset().left + $playingField.width() / 2 }
      var size = opts.size || { width: 50, height: 50 }
      var draggable = opts.draggable == undefined ? true : opts.draggable
      var resizable = opts.resizable == undefined ? true : opts.resizable

      var newZone = $("<div>", { class: "zone " + color }).css({ width: size.width, height: size.height })
      $('.card-game-container').append(newZone)
      newZone.css({ top: coord.top, left: coord.left })
      if (draggable) {
        newZone.draggable({ containment: ".playing-field" })
      }
      if (resizable) {
        newZone.resizable({
          containment: ".playing-field",
          handles: "all",
          classes: {
            "ui-resizable-se": ""
          }
        })
      }
    }

    $('.add-zone').click(function(evt) {
      evt.preventDefault()
      addZone()
      return false
    })
  }, 1)
})
