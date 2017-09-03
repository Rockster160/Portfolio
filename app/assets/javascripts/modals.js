$(document).ready(function() {
  showModal = function(modal_str) {
    var modal = $(modal_str)
    var content = $(modal).find(".modal-content")

    $(modal).css("opacity", 0).removeClass("hidden")
    modal.animate({ opacity: 1 }, 400)

    content.css({ top: -300 })
    content.animate({ top: 0 }, 400)
  }
  hideModal = function(modal_str) {
    var modal = $(modal_str)
    var content = $(modal).find(".modal-content")

    $(modal).css("opacity", 1).removeClass("hidden")
    modal.animate({ opacity: 0 }, {
      duration: 400,
      complete: function() {
        $(modal).css("opacity", 0).addClass("hidden")
      }
    })

    content.css({ top: 0 })
    content.animate({ top: -300 }, 400)
  }
  $("[data-modal]").click(function(evt) {
    evt.preventDefault()
    showModal($(this).attr("data-modal"))
    return false
  })
  $("[data-dismiss]").click(function(evt) {
    evt.preventDefault()
    hideModal($(this).attr("data-dismiss"))
    return false
  })

  $(window).click(function(evt) {
    if ($(evt.target).hasClass("modal")) {
      hideModal(".modal")
    }
  })
})
