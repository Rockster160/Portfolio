$('.ctr-cards').ready(function() {

  $('.add-zone').click(function(evt) {
    evt.preventDefault();
    var newZone = $("<div>", { class: "zone" });
    var $playingField = $('.playing-field');
    newZone.css({
      top: $playingField.offset().top + $playingField.height() / 2,
      left: $playingField.offset().left + $playingField.width() / 2
    })
    $('.card-game-container').append(newZone);
    newZone.draggable({
      containment: ".playing-field"
    });
    newZone.resizable({
      containment: ".playing-field"
    });
    return false;
  })

})
