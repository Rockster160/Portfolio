function flashReady() {

  $('.btn-updateJS').click(function() {
    reloadJS();
  })

  $(".center-btn").mouseup(function() {
    c = $(this).siblings("#flashcard-line");
    c.toggleClass("center");
  });

  $(".jsflip-btn").click(function() {
    $('.flashcard-container').toggleClass('flip');
  });

  $("#edit-btn").click(function() {
    if ($(this).html() == "Save") {
      $(this).closest('form').submit();
    }
  });

  document.onkeyup = function () {
    focused = document.activeElement.className;
    if (focused == "flashcard-class" || focused == "flashcard-class center") {
      var width = textWidth($(':focus').val(), "Comic Sans MS");
      tooWide(width, 290);
    }
    if (focused == "flashcard-class" || focused == "flashcard-class center") {
      var width = textWidth($(':focus').val(), "Comic Sans MS");
      tooWide(width, 290);
    }
    if (focused == "search-box") {
      updateSearch();
    }

    function tooWide(width, length) {
      if (width > length) {
        str = $(':focus').val().split("");
        str.pop();
        $(':focus').val(str.join(""));
        tooWide(textWidth($(':focus').val(), "Comic Sans MS"), length);
      }
    }

    function restrictScroll(id, max_lines) {
      var $foc = document.getElementById(id),
        style = (window.getComputedStyle) ? window.getComputedStyle($foc) : $foc.currentStyle,
        lineHeight = parseInt(style.lineHeight, 10),
        height = $foc.scrollHeight,
        lines = Math.floor(height/lineHeight);

      if (lines > max_lines) {
        $foc.value = $foc.value.substring(0, $foc.value.length-1);
        restrictScroll(id, max_lines);
      }
    };
  };

  function textWidth(text, font) {
    if (!textWidth.fakeEl) textWidth.fakeEl = $('<span class="hidden">').appendTo(document.body);
    var htmlText = text || this.val() || this.text();
    htmlText = textWidth.fakeEl.text(htmlText).html(); //encode to Html
    htmlText = htmlText.replace(/\s/g, "&nbsp;"); //replace trailing and leading spaces
    textWidth.fakeEl.html(htmlText).css('font', font || this.css('font'));
    width = textWidth.fakeEl.width();
    return width;
  };
}

function updateSearch() {
  var str = $('.search-box').val();
  var url = "/search.json";
  $.get(url, {q : str}, function(searchResults) {
    if (str.length > 0) {
      $('#left').html("")
      for(var i=0;i<searchResults.length;i++){
        console.log(searchResults[i][0]);
        $('#left').append('<div class="piece" onClick="liveBeenClicked(' +
          searchResults[i][0] +
          ');">' +
          searchResults[i][1] +
          '</div>');
      }
    }
    if (str.length == 0) { $('#left').html("") }
  });
}

function liveBeenClicked() {
  console.log(arguments);
  $('#right').html("")
  for(var i=0;i<arguments.length;i++){
    $('#right').append('<div class="piece">' +
      arguments[i] +
      '</div>');
  }
}

$(document).ready(flashReady);
$(document).on('page:load', flashReady());
// setInterval(function() {reloadJS()}, 5000);
