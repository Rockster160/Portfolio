var currentMouseCoord;
var prevSelect;
$(".ctr-cards").ready(function() {
  setTimeout(function() {
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
      $(".playing-field").append(dot);
    }

    deck = function() {
      return $("[data-zone-type='deck']")
    }

    organizeDeck = function() {
      var $deck = deck(),
        deckCoord = offsetCenterOfCard(deck().offset()),
        startCoord = {top: deckCoord.top - ($deck.height() / 2), left: deckCoord.left - ($deck.width() / 2)}
      var $cards = cardsInDeck()

      sortCardsByStackOrder($deck).each(function(idx) {
        $(this).closest(".card-container").css("z-index", idx + 1);
      })

      $cards.each(function(t) {
        $card = $(this)
        $card.jump(deckCoord.left + 20 - (t * 0.3), deckCoord.top + 25)
      })
      moveCardsToTopAndReorder()
    }

    shuffleDeck = function() {
      console.log("NotYetImplemented");
    }

    optimizeCardCoordsForField = function(coord) {
      return constrainCenteredCardCoordToField(offsetCenterOfCard(calibrateCoordForFieldPadding(coord)));
    }

    offsetCenterOfCard = function(coord, currentPositionIsTopLeft) {
      currentPositionIsTopLeft = currentPositionIsTopLeft || false;

      var cardSize = {width: $(".card").outerWidth(), height: $(".card").outerHeight()}
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
      var fieldPaddingLeft = parseInt($(".playing-field").css("padding-left")),
      fieldPaddingTop = parseInt($(".playing-field").css("padding-top"));
      return {left: coord.left - fieldPaddingLeft, top: coord.top - fieldPaddingTop};
    }

    calibrateCoordForFieldOffset = function(coord) {
      var fieldOffset = $(".playing-field").offset(),
      fieldOffsetLeft = fieldOffset.left,
      fieldOffsetTop = fieldOffset.top;
      return {left: coord.left - fieldOffsetLeft, top: coord.top - fieldOffsetTop};
    }

    constrainCenteredCardCoordToField = function(coord) {
      var cardSize = {width: $(".card").outerWidth(), height: $(".card").outerHeight()},
      fieldPaddingLeft = parseInt($(".playing-field").css("padding-left")),
      fieldPaddingTop = parseInt($(".playing-field").css("padding-top")),
      minX = 0,
      maxX = $(".playing-field").width() - cardSize.width,
      minY = 0,
      maxY = $(".playing-field").height() - cardSize.height;
      var constrainedCoord = {
        left: [minX, maxX, coord.left].sort(function(a, b) { return a - b; })[1],
        top:  [minY, maxY, coord.top ].sort(function(a, b) { return a - b; })[1]
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
      flipOnLand = opts.flipOnLand || false
      duration = opts.duration || 200
      var cards = [];
      for (i=0;i<count;i++) {
        var nextCoord = {top: startCoord.top + (spacing.top * i), left: startCoord.left + (spacing.left * i)}
        var card = drawCard();
        cards.push(card)
        animateCardToCoords(card, nextCoord, duration, function(card) {
          if (flipOnLand) { flipCard(card) }
          if (opts.callback && typeof(opts.callback) === "function") { opts.callback(card) }
        });
      }
      return cards;
    }

    addCardToDeck = function(card) {
      var $cardContainer = $(card).closest(".card-container"), $card = $cardContainer.find(".card")
      deck().append($cardContainer.css("z-index", 0))
      $(card)
        .removeClass("flipped")
        .removeClass("active")
        .removeClass("dragging")
        .removeClass("ui-selected")
        .removeClass("ui-selecting")
      var deckCoords = deck().position(),
        cardCoords = calibrateCoordForFieldPadding(deckCoords);
      $(card).jump(cardCoords.left, cardCoords.top);
      organizeDeck()
      return card;
    }

    popCardOffDeck = function(card) {
      $(".playing-field").append($(card).closest(".card-container"));
      moveCardsToTopAndReorder(card);
      var deckCoords = deck().position()
        // cardCoords = calibrateCoordForFieldPadding(deckCoords)
      $(card).jump(deckCoords.left, deckCoords.top);
      return card;
    }

    animateCardToCoords = function(card, destCoord, duration, callback) {
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
          if (callback && typeof(callback) === "function") { callback(card) }
        }
      }, msPerFrame);
    }

    cardIsInDeck = function(card) {
      return $(card).parents("[data-zone-type='deck']").length > 0;
    }

    cardsInDeck = function() {
      return sortCardsByStackOrder($("[data-zone-type='deck'] .card"));
    }

    cardsInPlay = function() {
      return sortCardsByStackOrder($(":not([data-zone-type='deck']) > .card-container .card"));
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
        var newIdx = opts.reverse ? $(".card").length + card_count - idx : $(".card").length + 2 + idx;
        $(this).closest(".card-container").css("z-index", newIdx);
      })
      var deckCount = cardsInDeck().length
      sortCardsByStackOrder(cardsInPlay()).each(function(idx) {
        $(this).closest(".card-container").css("z-index", deckCount + idx);
      })
    }

    stackPositionForCard = function(card) {
      return parseInt($(card).closest(".card-container").css("z-index")) || 0;
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

    $(window).keydown(function(evt) {
      if (evt.which == keyEvent("SPACE")) {
        evt.preventDefault()
        if ($(".ui-selected").length > 0) {
          cards = $(".ui-selected.card");
          flipCard(cards)
        }
        return false
      } else {
        switch (String.fromCharCode(evt.which)) {
          case "D":
            dealCard({startCoord: optimizeCardCoordsForField(currentMouseCoord), flipOnLand: evt.shiftKey});
          break;
          case "T":
            addDot(currentMouseCoord.left, currentMouseCoord.top);
          break;
        }
      }
    });

    $(window).mousemove(function(evt) {
      // offset, client, screen
      currentMouseCoord = calibrateCoordForFieldOffset({left: evt.clientX, top: evt.clientY});
    })

    $(".card").mousedown(function(evt) {
      $(".active").removeClass("active");
      $(".dragging").removeClass("dragging");
      if (evt.shiftKey || evt.ctrlKey || evt.metaKey) {
        return $(this).toggleClass("ui-selected");
      }
      if (!cardIsInDeck(this)) {
        $(this).addClass("active");
      }
      $(this).one("mouseup", function() {
        $(this).off("mousemove.beforeDrag");
      });

      $(this).one("mousemove.beforeDrag", function() {
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

    $(".card").draggable({
      containment: ".playing-field",
      start: function(evt) {
        $this = $(this);
        if ($this.hasClass("ui-selected")) {
          moveCardsToTopAndReorder(sortCardsByStackOrder($(".ui-selected.card")));
        } else {
          $(".ui-selected").removeClass("ui-selected");
          moveCardsToTopAndReorder(this);
        }
        $(".card.ui-selected:not(.dragging)").each(function() {
          var oldPos = $(this).position();
          $(this).attr("save-pos-left", oldPos.left);
          $(this).attr("save-pos-top", oldPos.top);
        })
      },
      drag: function(evt, ui) {
        $(this).addClass("dragging");
        var $this = $(ui.helper), delta = {top: ui.originalPosition.top - ui.position.top, left: ui.originalPosition.left - ui.position.left};
        if ($this.hasClass("ui-selected")) {
          $(".card.ui-selected:not(.dragging)").each(function() {
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

        var $deck = deck()
        var deckPos = $deck.position()
        var deckBB = {
          left: deckPos.left,
          top: deckPos.top,
          right: deckPos.left + $deck.outerWidth(),
          bottom: deckPos.top + $deck.outerHeight()
        }
        // If dropped cards into the deck
        if (currentMouseCoord.left > deckBB.left && currentMouseCoord.left < deckBB.right) {
          // Horz coords match
          if (currentMouseCoord.top > deckBB.top && currentMouseCoord.top < deckBB.bottom) {
            // Vert coords match
            $(".ui-selected, .ui-draggable-dragging").each(function() {
              addCardToDeck(this)
            })
          }
        }
      }
    });
    var selectingFlipped = undefined
    $(".playing-field").selectable({
      filter: ".card",
      start: function(e, ui) {
        if ($(".ui-selected").length == 0) { selectingFlipped = undefined }
      },
      selecting: function(e, ui) {
        var $this = $(ui.selecting);

        // Prevent cards in the deck from being selected
        if ($this.hasClass("deck") || $this.parents("[data-zone-type='deck']").length > 0) {
          return $this.removeClass("ui-selecting");
        }

        // Can only select cards facing the same direction
        if (selectingFlipped == undefined) {
          selectingFlipped = $this.hasClass("flipped")
        } else if (selectingFlipped) {
          if (!$this.hasClass("flipped")) { $this.removeClass("ui-selecting") }
        } else {
          if ($this.hasClass("flipped")) { $this.removeClass("ui-selecting") }
        }
      }
    });

    organizeDeck()
  }, 0)
})
