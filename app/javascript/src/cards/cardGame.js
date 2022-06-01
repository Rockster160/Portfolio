$(document).ready(function() {
  if ($(".ctr-cards").length == 0) { return }
  setTimeout(function() {
    if (params.game == "solitaire") {
      var cardWidth = 100
      var $playingField = $('.playing-field'), fieldPadding = parseInt($playingField.css("padding")), fieldBB = {}
      fieldBB.top    = $playingField.offset().top,
      fieldBB.left   = $playingField.offset().left,
      fieldBB.right  = fieldBB.left + $playingField.innerWidth() - (fieldPadding * 2)
      fieldBB.bottom = fieldBB.top + $playingField.innerHeight() - (fieldPadding * 2)
      var topRight = { top: fieldBB.top + fieldPadding, left: fieldBB.right - cardWidth + fieldPadding }
      var zoneCoord = $.extend({}, topRight)
      addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: false, resizable: false})
      zoneCoord.left -= 120
      addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: false, resizable: false})
      zoneCoord.left -= 120
      addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: false, resizable: false})
      zoneCoord.left -= 120
      addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: false, resizable: false})

      var moveDownPerLayer = 15
      var distanceBetweenCards = 20
      var moveLeftPerLayer = cardWidth + distanceBetweenCards
      var cardCoord = $.extend({}, topRight)
      var cardStartLeft = fieldBB.right - ((cardWidth + distanceBetweenCards) * 7)
      cardCoord.top += 100

      var q = new Queue()
      // Next Row
      q.add(function(queue) {
        cardCoord.left = cardStartLeft
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: true, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })

      // Next Row
      q.add(function(queue) {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: true, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })

      // Next Row
      q.add(function(queue) {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: true, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })

      // Next Row
      q.add(function(queue) {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: true, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })

      // Next Row
      q.add(function(queue) {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: true, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })

      // Next Row
      q.add(function(queue) {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: true, callback: Queue.finish(queue)})
      })
      q.add(function(queue) {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: false, callback: Queue.finish(queue)})
      })

      // Next Row
      q.add(function(queue) {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 50, flipOnLand: true, callback: Queue.finish(queue)})
      })

      q.process()
    } // game: solitaire
  }, 5)
})
