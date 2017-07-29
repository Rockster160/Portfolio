$('.ctr-little_worlds.act-character_builder').ready(function() {

  var nextQueueTimer, animationQueue = [];
  // Must be kept in sync with CSS values!
  var spellAnimationDuration = 1000;
  var thrustAnimationDuration = 1000;
  var walkAnimationDuration = 800;
  var slashAnimationDuration = 500;
  var shootAnimationDuration = 1200;
  var dieAnimationDuration = 1000;

  var currentTime = function() { return (new Date).getTime() }

  var getCurrentDirection = function() {
    if ($('.character').hasClass("stand-up")) { return "up" }
    if ($('.character').hasClass("stand-left")) { return "left" }
    if ($('.character').hasClass("stand-right")) { return "right" }
    if ($('.character').hasClass("stand-down")) { return "down" }
    return "down"
  }

  var switchDirection = function(newDirection) {
    clearMovementClasses()
    $('.character').removeClass("stand-up stand-down stand-left stand-right")
    $('.character').addClass("stand-" + newDirection)
  }

  var addToQueue = function(newEvent) {
    animationQueue.push(newEvent);
    if (!nextQueueTimer) {
      runFromQueue()
    }
  }

  var clearQueue = function() {
    animationQueue = [];
  }

  var runAnimationTimer = function(timeOffset) {
    nextQueueTimer = setTimeout(runFromQueue, timeOffset)
  }

  var clearMovementClasses = function() {
    $('.character').removeClass("spell-up spell-down spell-left spell-right thrust-up thrust-down thrust-left thrust-right walk-up walk-down walk-left walk-right slash-up slash-down slash-left slash-right shoot-up shoot-down shoot-left shoot-right die")
  }

  var move = function(direction) {
    switchDirection(direction)
    void $('.character')[0].offsetWidth
    $('.character').addClass("walk-" + direction)
    runAnimationTimer(walkAnimationDuration)
  }

  var doSpell = function() {
    void $('.character')[0].offsetWidth
    $('.character').addClass("spell-" + getCurrentDirection())
    runAnimationTimer(spellAnimationDuration)
  }

  var doThrust = function() {
    void $('.character')[0].offsetWidth
    $('.character').addClass("thrust-" + getCurrentDirection())
    runAnimationTimer(thrustAnimationDuration)
  }

  var doSlash = function() {
    void $('.character')[0].offsetWidth
    $('.character').addClass("slash-" + getCurrentDirection())
    runAnimationTimer(slashAnimationDuration)
  }

  var doShoot = function() {
    void $('.character')[0].offsetWidth
    $('.character').addClass("shoot-" + getCurrentDirection())
    runAnimationTimer(shootAnimationDuration)
  }

  var doDie = function() {
    void $('.character')[0].offsetWidth
    $('.character').addClass("die")
    runAnimationTimer(dieAnimationDuration)
  }

  var runFromQueue = function(evt) {
    clearMovementClasses()
    nextQueueTimer = null
    var nextEvent = animationQueue.shift()
    if (!nextEvent) { return }

    switch(nextEvent.split("-")[0]) {
      case "left":
      move("left")
      break;
      case "right":
      move("right")
      break;
      case "up":
      move("up")
      break;
      case "down":
      move("down")
      break;
      case "spell":
      doSpell()
      break;
      case "thrust":
      doThrust()
      break;
      case "slash":
      doSlash()
      break;
      case "shoot":
      doShoot()
      break;
      case "die":
      doDie()
      break;
    }
  }

  $(document).keydown(function(evt) {
    switch(evt.which) {
      case keyEvent("LEFT"):
      addToQueue("left")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("RIGHT"):
      addToQueue("right")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("UP"):
      addToQueue("up")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("DOWN"):
      addToQueue("down")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("A"):
      addToQueue("spell")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("S"):
      addToQueue("thrust")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("D"):
      addToQueue("slash")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("F"):
      addToQueue("shoot")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("G"):
      addToQueue("die")
      evt.preventDefault();
      return false;
      break;
      case keyEvent("X"):
      clearQueue()
      evt.preventDefault();
      return false;
      break;
    }
  })

})
