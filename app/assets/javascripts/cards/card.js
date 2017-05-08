$('.ctr-cards').ready(function() {

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
  $(window).keypress(function(evt) {
    if (evt.which == KEY_EVENT_SPACE) {
      if (allFlipped) {
        flipCard(cardsInPlay(), "up");
        allFlipped = false;
      } else {
        flipCard(cardsInPlay(), "down");
        allFlipped = true;
      }
    }
  });

  $('.card').mousedown(function(evt) {
    if (!cardIsInDeck(this)) {
      $(this).addClass("selected");
    }
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
      if (cardIsInDeck(this)) {
        var deckOffsetX = $('.deck').offset().left - $(this).parent().offset().left,
            currentOffsetX = parseInt($(this).css("left")),
            cardOffsetX = currentOffsetX + deckOffsetX + ($('.deck').outerWidth() * 2) - 2,
            cardOffsetY = 30;
        $('.playing-field').append($(this).parent());
        $(this).css({"left": cardOffsetX + "px", "top": parseInt($(this).css("top")) + cardOffsetY + "px"});
      }
      moveCardsToTopAndReorder();
    }
  });

})
