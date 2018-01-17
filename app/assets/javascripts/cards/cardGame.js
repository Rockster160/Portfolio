$('.ctr-cards').ready(function() {
  // FIXME: The timings in this file are VERY sensitive
  // Somehow we're losing the scope of the card when dealing/flipping
  setTimeout(function() {
    if (params.game == "solitaire") {
      var cardWidth = 100
      var $playingField = $('.playing-field'), fieldPadding = parseInt($playingField.css("padding")), fieldBB = {}
      fieldBB.top    = $playingField.offset().top,
      fieldBB.left   = $playingField.offset().left,
      fieldBB.right  = fieldBB.left + $playingField.innerWidth() - (fieldPadding * 2)
      fieldBB.bottom = fieldBB.top + $playingField.innerHeight() - (fieldPadding * 2)
      addDot(fieldBB.left, fieldBB.top)
      addDot(fieldBB.left, fieldBB.bottom)
      addDot(fieldBB.right, fieldBB.top)
      addDot(fieldBB.right, fieldBB.bottom)
      var topRight = { top: fieldBB.top + fieldPadding, left: fieldBB.right - cardWidth + fieldPadding }
      var zoneCoord = $.extend({}, topRight)
      addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: true, resizable: false})
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
      var timeBetweenEachDeal = 300

      setTimeout(function() {
        cardCoord.top += 100
        cardCoord.left = cardStartLeft
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: true})
      }, 5)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 1)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 2)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 3)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 4)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 5)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 6)

      setTimeout(function() {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: true})
      }, timeBetweenEachDeal * 7)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 8)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 9)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 10)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 11)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 12)

      setTimeout(function() {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: true})
      }, timeBetweenEachDeal * 13)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 14)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 15)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 16)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 17)

      setTimeout(function() {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: true})
      }, timeBetweenEachDeal * 18)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 19)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 20)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 21)

      setTimeout(function() {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: true})
      }, timeBetweenEachDeal * 22)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 23)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 24)

      setTimeout(function() {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: true})
      }, timeBetweenEachDeal * 25)
      setTimeout(function() {
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: false})
      }, timeBetweenEachDeal * 26)

      setTimeout(function() {
        cardCoord.top += moveDownPerLayer
        cardCoord.left = cardStartLeft
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        cardCoord.left += moveLeftPerLayer
        dealCard({startCoord: cardCoord, duration: 100, flipOnLand: true})
      }, timeBetweenEachDeal * 27)
    } // game: solitaire
  }, 1000)
})
