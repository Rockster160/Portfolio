$(document).ready(function() {
  showModal = function(modal_str) {
    var modal = $(modal_str)
    var content = $(modal).find(".modal-content")

    $(modal).css("opacity", 0).removeClass("hidden").addClass("shown")
    modal.animate({ opacity: 1 }, 300)

    content.css({ top: -300 })
    content.animate({ top: 0 }, 300)
    modal.trigger("modal.shown")
  }
  hideModal = function(modal_str) {
    if (!modal_str) { hideModal(".modal.shown") }
    var modal = $(modal_str)
    var content = $(modal).find(".modal-content")

    $(modal).css("opacity", 1).removeClass("hidden").addClass("shown")
    modal.animate({ opacity: 0 }, {
      duration: 300,
      complete: function() {
        $(modal).css("opacity", 0).addClass("hidden").removeClass("shown")
      }
    })

    content.css({ top: 0 })
    content.animate({ top: -300 }, 300)
    modal.trigger("modal.hidden")
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
      hideModal(".modal.shown")
    }
  })
  $("[data-onload-modal]").each(function() {
    showModal($(this).attr("data-onload-modal"))
    this.remove()
  })
})
