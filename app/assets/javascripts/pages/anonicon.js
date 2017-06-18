$('.ctr-anonicons.act-index').ready(function() {

  $('.random-anonicon').click(function(evt) {
    evt.preventDefault();
    var rand_str = [], possible = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    for (var i=0; i<32; i++) {
      var chosen = possible.charAt(Math.floor(Math.random() * possible.length));
      rand_str.push(chosen);
    }
    $("#anon_str").val(rand_str.join(""));
    $("#anonicon-form").submit();
    return false;
  })

  $("#anonicon-form").submit(function(evt) {
    evt.preventDefault();
    $('.anonicon-container').html('<i class="fa fa-spinner fa-spin fa-3x"></i>');
    $.get($(this).attr("action"), $(this).serialize()).success(function(data) {
      $('.anonicon-container').html(data);
    })
    return false;
  })

})
