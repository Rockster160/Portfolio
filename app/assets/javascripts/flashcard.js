$(document).ready(function() {
  $(".center-button").click(function() {
    $(this).siblings().toggleClass("center");
    console.log($(this).siblings().html());
  })
})
