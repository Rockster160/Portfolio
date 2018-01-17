$('.ctr-cards').ready(function() {
  // FIXME: The timings in this file are VERY sensitive
  // Somehow we're losing the scope of the card when dealing/flipping
  setTimeout(function() {
    var cardWidth = 100
    var $playingField = $('.playing-field'), zoneCoord;
    var topRight = { top: $playingField.offset().top + 25, left: $playingField.offset().left + $playingField.outerWidth() - 25 - cardWidth }
    zoneCoord = $.extend({}, topRight)
    addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: false, resizable: false})
    zoneCoord.left -= 120
    addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: false, resizable: false})
    zoneCoord.left -= 120
    addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: false, resizable: false})
    zoneCoord.left -= 120
    addZone({color: "blue", size: { width: cardWidth, height: 130 }, coord: zoneCoord, draggable: false, resizable: false})

    var moveDownPerLayer = 15
    var moveLeftPerLayer = cardWidth + 20
    var cardCoord = $.extend({}, topRight)
    var cardStartLeft = topRight.left - (moveLeftPerLayer * 7) + 17
    var timeBetweenEachDeal = 300

    setTimeout(function() {
      cardCoord.top += 70
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
  }, 1000)
})
