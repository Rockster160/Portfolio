var currentMouseCoord;
var prevSelect;
$('.ctr-cards').ready(function() {

  $.fn.jump = function(x, y) {
    this.css({"left": x + "px", "top": y + "px"});
    return this;
  }

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
    $('.playing-field').append(dot);
  }

  optimizeCardCoordsForField = function(coord) {
    return constrainCenteredCardCoordToField(offsetCenterOfCard(calibrateCoordForFieldPadding(coord)));
  }

  offsetCenterOfCard = function(coord, currentPositionIsTopLeft) {
    currentPositionIsTopLeft = currentPositionIsTopLeft || false;

    var cardSize = {width: $('.card').outerWidth(), height: $('.card').outerHeight()}
    var tempCoord = {
      left: coord.left - (cardSize.width / 2),
      top: coord.top - (cardSize.height / 2)
    }
    if (currentPositionIsTopLeft) {
      tempCoord = { left: tempCoord.left - cardSize.width, top: tempCoord.top - cardSize.height }
    }
    return tempCoord;
  }

  calibrateCoordForFieldPadding = function(coord) {
    var fieldPaddingLeft = parseInt($('.playing-field').css("padding-left")),
        fieldPaddingTop = parseInt($('.playing-field').css("padding-top"));
    return {left: coord.left - fieldPaddingLeft, top: coord.top - fieldPaddingTop};
  }

  calibrateCoordForFieldOffset = function(coord) {
    var fieldOffset = $('.playing-field').offset(),
        fieldOffsetLeft = fieldOffset.left,
        fieldOffsetTop = fieldOffset.top;
    return {left: coord.left - fieldOffsetLeft, top: coord.top - fieldOffsetTop};
  }

  constrainCenteredCardCoordToField = function(coord) {
    var cardSize = {width: $('.card').outerWidth(), height: $('.card').outerHeight()},
        fieldPaddingLeft = parseInt($('.playing-field').css("padding-left")),
        fieldPaddingTop = parseInt($('.playing-field').css("padding-top")),
        minX = 0,
        maxX = $('.playing-field').width() - cardSize.width,
        minY = 0,
        maxY = $('.playing-field').height() - cardSize.height;
    var constrainedCoord = {
      left: [minX, maxX, coord.left].sort(function(a, b) { return a - b; })[1],
      top: [minY, maxY, coord.top].sort(function(a, b) { return a - b; })[1]
    }
    return constrainedCoord;
  }

  drawCard = function() {
    var topCard = deckTopCard();
    if (topCard == undefined) { return }
    popCardOffDeck(topCard);
    return topCard;
  }

  dealCard = function(opts) {
    opts = opts || {}
    count = opts.count || 1
    startCoord = opts.startCoord || {top: 0, left: 0}
    spacing = opts.spacing || {top: 0, left: 0}
    var cards = [];
    for (i=0;i<count;i++) {
      var nextCoord = {top: startCoord.top + (spacing.top * i), left: startCoord.left + (spacing.left * i)}
      var card = drawCard();
      cards.push(card)
      animateCardToCoords(card, nextCoord);
    }
    return cards;
  }

  popCardOffDeck = function(card) {
    $('.playing-field').append($(card).parent());
    moveCardsToTopAndReorder(card);
    var deckCoords = $('.deck').position(),
        cardCoords = calibrateCoordForFieldPadding(deckCoords);
    $(card).jump(cardCoords.left + $('.deck').outerWidth(), cardCoords.top);
    return card;
  }

  animateCardToCoords = function(card, destCoord, duration) {
    if (card.length == 0) { return };
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

  cardsInDeck = function() {
    return sortCardsByStackOrder($(".deck .card"));
  }

  cardsInPlay = function() {
    return sortCardsByStackOrder($(":not(.deck) > .card-container .card"));
  }

  deckTopCard = function() {
    return cardsInDeck().last();
  }

  displayValueOfCard = function(card) {
    return $(card).attr("rank");
  }

  moveCardsToTopAndReorder = function(cards, opts) {
    opts = opts || {}
    var $cards = sortCardsByStackOrder(cards), card_count = $cards.length;
    $cards.each(function(idx) {
      var newIdx = opts.reverse ? $('.card').length + card_count - idx : $('.card').length + 2 + idx;
      $(this).parent().css('z-index', newIdx);
    })
    sortCardsByStackOrder(cardsInPlay()).each(function(idx) {
      $(this).parent().css('z-index', idx + 1);
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
    moveCardsToTopAndReorder($(card_selector), {reverse: true});
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
    if (evt.which == keyEvent("SPACE")) {
      if ($('.ui-selected').length > 0) {
        cards = $('.ui-selected.card');
      } else {
        cards = cardsInPlay();
      }
      flipCard(cards);
      // if (allFlipped) {
      //   flipCard(cards, "up");
      //   allFlipped = false;
      // } else {
      //   flipCard(cards, "down");
      //   allFlipped = true;
      // }
      // TODO: Should have separate controls to make all cards go down/up/toggle
    } else {
      switch (String.fromCharCode(evt.which)) {
        case "d", "D":
          dealCard({startCoord: optimizeCardCoordsForField(currentMouseCoord)});
          break;
        case "T":
          addDot(currentMouseCoord.left, currentMouseCoord.top);
          break;
        case "S":
          var cards = dealCard({count: 3, spacing: {top: 0, left: -25}, startCoord: {top: 0, left: 50}})
          setTimeout(function() {
            flipCard(cards);
          }, 200)
      }
    }
  });

  $(window).mousemove(function(evt) {
    // offset, client, screen
    currentMouseCoord = calibrateCoordForFieldOffset({left: evt.clientX, top: evt.clientY});
  })

  $('.card').mousedown(function(evt) {
    $(".active").removeClass("active");
    $(".dragging").removeClass("dragging");
    if (evt.shiftKey || evt.ctrlKey || evt.metaKey) {
      return $(this).toggleClass("ui-selected");
    }
    if (!cardIsInDeck(this)) {
      $(this).addClass("active");
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
    if (!$(this).hasClass("dragging") && $(this).hasClass("active")) {
      flipCard(this);
    }
    $(".active").removeClass("active");
    $(".dragging").removeClass("dragging");
  })

  $('.card').draggable({
    containment: '.playing-field',
    start: function(evt) {
      $this = $(this);
      if ($this.hasClass("ui-selected")) {
        moveCardsToTopAndReorder(sortCardsByStackOrder($('.ui-selected.card')));
      } else {
        $('.ui-selected').removeClass('ui-selected');
        moveCardsToTopAndReorder(this);
      }
      $('.card.ui-selected:not(.dragging)').each(function() {
        var oldPos = $(this).position();
        $(this).attr("save-pos-left", oldPos.left);
        $(this).attr("save-pos-top", oldPos.top);
      })
    },
    drag: function(evt, ui) {
      $(this).addClass("dragging");
      var $this = $(ui.helper), delta = {top: ui.originalPosition.top - ui.position.top, left: ui.originalPosition.left - ui.position.left};
      if ($this.hasClass("ui-selected")) {
        $('.card.ui-selected:not(.dragging)').each(function() {
          var oldPos = {top: parseInt($(this).attr("save-pos-top")), left: parseInt($(this).attr("save-pos-left"))};
          var newCoord = {top: oldPos.top - delta.top, left: oldPos.left - delta.left};
          $(this).css(constrainCenteredCardCoordToField(newCoord));
        })
      }
    },
    stop: function(evt) {
      $("[save-pos-left]").removeAttr("save-pos-left");
      $("[save-pos-top]").removeAttr("save-pos-top");
      moveCardsToTopAndReorder();
    }
  });
// When CMD clicking a card, should flip all selected cards?
  $('.playing-field').selectable({
    filter: ".card",
    selecting: function(e, ui) {
      var $this = $(ui.selecting);
      if ($this.hasClass("deck") || $this.parents(".deck").length > 0) {
        $this.removeClass('ui-selecting');
      }
    }
  });

  moveCardsToTopAndReorder();
})
