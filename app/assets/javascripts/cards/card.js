var currentMouseCoord;
$('.ctr-cards').ready(function() {

  addDot = function(x, y) {
    var dot = $("<div>");
    dot.css({
      position: "absolute",
      top: y + "px",
      left: x + "px",
      width: "1px",
      height: "1px",
      zIndex: 9999,
      background: "red"
    })
    $('.playing-field').append(dot)
  }

  optimizeCardCoordsForField = function(coord) {
    return constrainCenteredCardCoordToField(removeFieldPadding(offsetCenterOfCard(coord)));
  }

  offsetCenterOfCard = function(coord) {
    var cardSize = {width: $('.card').outerWidth(), height: $('.card').outerHeight()}
    return {left: coord.left - (cardSize.width / 2), top: coord.top - (cardSize.height / 2)}
  }

  removeFieldPadding = function(coord) {
    var fieldPaddingLeft = parseInt($('.playing-field').css("padding-left")),
        fieldPaddingTop = parseInt($('.playing-field').css("padding-top"));
    return {left: coord.left - fieldPaddingLeft, top: coord.top - fieldPaddingTop};
  }

  constrainCenteredCardCoordToField = function(coord) {
    var cardSize = {width: $('.card').outerWidth(), height: $('.card').outerHeight()},
        fieldPaddingLeft = parseInt($('.playing-field').css("padding-left")),
        fieldPaddingTop = parseInt($('.playing-field').css("padding-top")),
        minX = fieldPaddingLeft + (cardSize.width / 2),
        maxX = $('.playing-field').outerWidth() - fieldPaddingLeft - (cardSize.width / 2),
        minY = fieldPaddingTop + (cardSize.height / 2),
        maxY = $('.playing-field').outerHeight() - fieldPaddingTop - (cardSize.height / 2);
    var constrainedCoord = {
      left: [minX, maxX, coord.left].sort(function(a, b) { return a - b; })[1],
      top: [minY, maxY, coord.top].sort(function(a, b) { return a - b; })[1]
    }
    return constrainedCoord;
  }

  $.fn.jump = function(x, y) {
    this.css({"left": x + "px", "top": y + "px"});
    console.log("JUMP (" + x + ", " + y + ")");
    return this;
  }

  drawCard = function() {
    var topCard = deckTopCard();
    if (topCard == undefined) { return }
    popCardOffDeck(topCard);
    return topCard;
  }

  popCardOffDeck = function(card) {
    $('.playing-field').append($(card).parent());
    moveCardsToTopAndReorder(card);
    var deckCoords = $('.deck').position(), cardCoords = removeFieldPadding(deckCoords)
    $(card).jump(cardCoords.left + $('.deck').outerWidth(), cardCoords.top);
    return card;
  }

  deckTopCard = function() {
    return $('.deck .card-container:last-of-type .card');
  }

  animateCardToCoords = function(card, destCoord, duration) {
    duration = duration || 200;
    var cardPos = $(card).position(),
        startCoord = { left: cardPos.left, top: cardPos.top },
        xDelta = destCoord.left - startCoord.left,
        yDelta = destCoord.top - startCoord.top,
        xPerMs = xDelta / duration,
        yPerMs = yDelta / duration,
        msPerFrame = 10,
        currentFrame = 0,
        frameCount = duration / msPerFrame;

    var cardAnimateInterval = setInterval(function() {
      var relX = (xPerMs * msPerFrame) * currentFrame;
      var relY = (yPerMs * msPerFrame) * currentFrame;
      $(card).jump(startCoord.left + relX, startCoord.top + relY)
      currentFrame += 1;
      if (currentFrame >= frameCount) {
        $(card).jump(destCoord.left, destCoord.top);
        clearInterval(cardAnimateInterval);
      }
    }, msPerFrame);
  }

  cardIsInDeck = function(card) {
    return $(card).parents(".deck").length > 0;
  }

  cardsInPlay = function() {
    return $(":not(.deck) > .card-container .card");
  }

  moveCardsToTopAndReorder = function(cards) {
    $(cards).each(function(idx) {
      $(this).parent().css('z-index', cardsInPlay().length + 1 + idx);
    })
    sortCardsByStackOrder(cardsInPlay()).each(function(idx) {
      $(this).parent().css('z-index', idx);
    })
  }

  stackPositionForCard = function(card) {
    return parseInt($(card).parent().css('z-index')) || 0;
  }

  sortCardsByStackOrder = function(cards) {
    return $(cards).sort(function (a, b) {
      var aStack = stackPositionForCard(a);
      var bStack = stackPositionForCard(b);
      return bStack < aStack ? 1 : -1;
    })
  }

  flipCard = function(card_selector, direction) {
    if (cardIsInDeck(this)) { return false }
    if (direction == "up") {
      $(card_selector).removeClass("flipped");
    } else if (direction == "down") {
      $(card_selector).addClass("flipped");
    } else {
      $(card_selector).toggleClass("flipped");
    }
  }

  var allFlipped = false;
  $(window).keydown(function(evt) {
    if (evt.which == KEY_EVENT_SPACE) {
      if (allFlipped) {
        flipCard(cardsInPlay(), "up");
        allFlipped = false;
      } else {
        flipCard(cardsInPlay(), "down");
        allFlipped = true;
      }
    } else {

      switch (String.fromCharCode(evt.which)) {
        case "d", "D":
          animateCardToCoords(drawCard(), offsetCenterOfCard(removeFieldPadding(currentMouseCoord)));
          break;
      }
    }
  });

  $(window).mousemove(function(evt) {
    // offset, client, screen
    currentMouseCoord = {left: evt.clientX, top: evt.clientY};
  })

  $('.card').mousedown(function(evt) {
    if (!cardIsInDeck(this)) {
      $(this).addClass("selected");
    }
    $(this).one('mouseup', function() {
      $(this).off('mousemove.beforeDrag');
    });

    $(this).one('mousemove.beforeDrag', function() {
      if (cardIsInDeck(this)) {
        popCardOffDeck(this);
      }
    });
  }).mouseup(function(evt) {
    if (!$(this).hasClass("dragging") && $(this).hasClass("selected")) {
      flipCard(this);
    }
    $(this).removeClass("selected");
    $(this).removeClass("dragging");
  })

  $('.card').draggable({
    containment: '.playing-field',
    start: function(evt) {
      $(this).parent().css("z-index", cardsInPlay().length + 10);
    },
    drag: function(evt) {
      $(this).addClass("dragging");
    },
    stop: function(evt) {
      moveCardsToTopAndReorder();
    }
  });

})
