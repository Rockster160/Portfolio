$(document).ready(function() {

  function reloadFlashCards(id) {
    url = 'flashcard';
    $.get(url, {pass_id : id}, function(data) {
      console.log(data);
      // $('html').html(data);
    });
  }

  $('.new-flashcard-btn').click(function() {
    reloadFlashCards(1);
  })

  $(".center-btn").click(function() {
    c = $(this).siblings("#flashcard-line");
    c.toggleClass("center");
  });

  $(".flip-btn").click(function() {
    $('.flashcard-container').toggleClass('flip');
  });

  document.onkeyup = function () {
    focused = document.activeElement.className;
    if (focused == "flashcard-class" || focused == "flashcard-class center") {
      var width = textWidth($(':focus').val(), "Comic Sans MS");
      tooWide(width, 290);
    }
    if (focused == "back-textbox") {
      restrictScroll('back-textbox-id', 12);
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
})
