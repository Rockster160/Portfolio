$(".ctr-money_buckets").ready(function() {
  var template = document.querySelector("#bucket-form")

  $(".add-bucket-btn").click(function() {
    var clone = template.content.cloneNode(true)

    $(".buckets").append(clone)

    if ($("input[type=checkbox]:checked").length == 0) {
      $("input[type=checkbox]").first().prop("checked", true)
    }
  })

  $(document).on("click", ".bucket-remove", function() {
    if (confirm("Are you sure you want to delete?")) {
      $(this).parents(".bucket").remove()
    }
  })

  $(".buckets").sortable({
    handle: ".bucket-handle",
  })

  $(document).on("click", ".bucket-default-checkbox", function() {
    $(".bucket-default-checkbox").siblings("input").prop("checked", false)
    $(this).siblings("input").prop("checked", true)
  })
})
