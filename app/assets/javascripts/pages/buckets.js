$(".ctr-money_buckets").ready(function() {
  var template = document.querySelector("#bucket-form")

  $(".add-bucket-btn").click(function() {
    var clone = template.content.cloneNode(true)

    $(".buckets").append(clone)
  })

  $(".buckets").sortable({
    handle: ".bucket-handle",
  })

  $(document).on("click", ".bucket-default-checkbox", function() {
    $(".bucket-default-checkbox").siblings("input").prop("checked", false)
    $(this).siblings("input").prop("checked", true)
  })
})
