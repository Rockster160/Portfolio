$(document).ready(function() {

  $(".center-btn").click(function() {
    c = $(this).siblings("#flashcard-line");
    c.toggleClass("center");
  });

  document.onkeyup = function () {
    focused = document.activeElement.className;
    if (focused == "flashcard-class" || focused == "flashcard-class center") {
      var width = textWidth($(':focus').val(), "Comic Sans MS");
      if (width > 300) {
        str = $(':focus').val().split("");
        str.pop();
        $(':focus').val(str.join(""));
      }
    }
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
