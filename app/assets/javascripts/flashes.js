flashRemoverTimer = null;

function resetFlashTimer(delay) {
  clearTimeout(flashRemoverTimer);
  flashRemoverTimer = setTimeout(function() {
    dismissFlash()
  }, delay || 8000)
}

dismissFlash = function() {
  $('body .flash-banner').animate({'right': '-350px'}, 500, function() {
    $(this).remove()
  })
}
$(document).on('click touchstart', '.dismiss-flash', function() {
  dismissFlash()
})
$(window).scroll(function() { dismissFlash(true) })

addFlash = function(message, type, delay) {
  $.get('/flash_message', {message: message, flash_type: type}, function(data) {
    dismissFlash();
    var flashMessageDiv = $(data);
    flashMessageDiv.addClass('hidden');
    $('body').append(flashMessageDiv);
    flashMessageDiv.css({'right': '-350px'});
    flashMessageDiv.removeClass('hidden');
    flashMessageDiv.animate({'right': '20px'}, 400);
  })
  resetFlashTimer(delay);
}

addFlashNotice = function(message, delay) {
  addFlash(message, 'notice', delay);
}

addFlashAlert = function(message, delay) {
  addFlash(message, 'alert', delay);
}

$(document).ready(function() {
  resetFlashTimer();
})
