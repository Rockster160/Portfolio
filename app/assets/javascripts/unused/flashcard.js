// function flashReady() {
//
//   $('.btn-updateJS').click(function() {
//     reloadJS();
//   })
//
//   $(".center-btn").mouseup(function() {
//     c = $(this).siblings("#flashcard-line");
//     c.toggleClass("center");
//   });
//
//   $(".jsflip-btn").click(function() {
//     $('.flashcard-container').toggleClass('flip');
//   });
//
//   $("#edit-btn").click(function() {
//     if ($(this).html() == "Save") {
//       $(this).closest('form').submit();
//     }
//   });
//
//   document.onkeyup = function () {
//     focused = document.activeElement.className;
//     if (focused == "flashcard-class" || focused == "flashcard-class center") {
//       var width = textWidth($(':focus').val(), "Comic Sans MS");
//       tooWide(width, 290);
//     }
//     if (focused == "flashcard-class" || focused == "flashcard-class center") {
//       var width = textWidth($(':focus').val(), "Comic Sans MS");
//       tooWide(width, 290);
//     }
//     if (focused == "search-box") {
//       updateSearch();
//     }
//
//     function tooWide(width, length) {
//       if (width > length) {
//         str = $(':focus').val().split("");
//         str.pop();
//         $(':focus').val(str.join(""));
//         tooWide(textWidth($(':focus').val(), "Comic Sans MS"), length);
//       }
//     }
//
//     function restrictScroll(id, max_lines) {
//       var $foc = document.getElementById(id),
//         style = (window.getComputedStyle) ? window.getComputedStyle($foc) : $foc.currentStyle,
//         lineHeight = parseInt(style.lineHeight, 10),
//         height = $foc.scrollHeight,
//         lines = Math.floor(height/lineHeight);
//
//       if (lines > max_lines) {
//         $foc.value = $foc.value.substring(0, $foc.value.length-1);
//         restrictScroll(id, max_lines);
//       }
//     };
//   };
//
//   function textWidth(text, font) {
//     if (!textWidth.fakeEl) textWidth.fakeEl = $('<span class="hidden">').appendTo(document.body);
//     var htmlText = text || this.val() || this.text();
//     htmlText = textWidth.fakeEl.text(htmlText).html(); //encode to Html
//     htmlText = htmlText.replace(/\s/g, "&nbsp;"); //replace trailing and leading spaces
//     textWidth.fakeEl.html(htmlText).css('font', font || this.css('font'));
//     width = textWidth.fakeEl.width();
//     return width;
//   };
// }
//
// function updateSearch() {
//   var str = $('.search-box').val();
//   var url = "/search.json";
//   $.get(url, {q : str}, function(searchResults) {
//     if (str.length > 0) {
//       $('#left').html("")
//       for(var i=0;i<searchResults.length;i++){
//         console.log(searchResults[i][0]);
//         //Change all of this to a partial with a local of the integer card id.
//         // Add onclick events to the partial:
//         // function, remove classes, add class to self
//         $('#left').append('<div class="cell batch highlight" onClick="liveBeenClicked(' +
//           searchResults[i][0] +
//           ');$(this).addClass();">' +
//           searchResults[i][1] +
//           '</div>');
//       }
//     }
//     if (str.length == 0) { $('#left').html("") }
//   });
// }
//
// function liveBeenClicked() {
//   // console.log(arguments);
//   // $('.cell').removeClass('highlight');
//   // $(this).addClass('highlight');
//   // var args = Array.prototype.slice.call(arguments, 1);
//   var args = arguments
//   // console.log(args);
//   $('#right').html("");
//   for(var i=0;i<args.length;i++){
//     $('#right').append('<div class="cell card">' +
//       args[i] +
//     '</div>');
//   }
// }
//
// $(document).ready(flashReady);
// $(document).on('page:load', flashReady());
