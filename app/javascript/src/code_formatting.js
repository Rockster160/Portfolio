$(document).ready(function() {
  if ($(".no-markdown").length > 0) { return }

  contrastForColor = function(bg_color_hex) {
    var black = "#000", white = "#FFF"
    if (!bg_color_hex) { return white }
    var color_hex = bg_color_hex.replace("#", "")

    var r_255, g_255, b_255;
    if (color_hex.length == 6) {
      r_255 = parseInt(color_hex[0] + color_hex[1], 16)
      g_255 = parseInt(color_hex[2] + color_hex[3], 16)
      b_255 = parseInt(color_hex[4] + color_hex[5], 16)
    } else if (color_hex.length == 3) {
      r_255 = parseInt(color_hex[0] + color_hex[0], 16)
      g_255 = parseInt(color_hex[1] + color_hex[1], 16)
      b_255 = parseInt(color_hex[2] + color_hex[2], 16)
    } else {
      return white
    }

    var r_lum = r_255 * 299, g_lum = g_255 * 587, b_lum = b_255 * 114
    var luminescence = ((r_lum + g_lum + b_lum) / 1000)

    return luminescence > 150 ? black : white
  }

  $("body:not(.ctr-jarvis_tasks, .ctr-tasks) *:not(script):not(noscript):not(style):not(iframe):not(.no-markdown):not(textarea):not(input)").each(function() {
    $(this).html($(this).html().replace(/([^\\])\`(.*?[^\\])\`/g, "$1<code>$2</code>"))
    $(this).html($(this).html().replace(/\\`/g, "`"))
    $(this).html($(this).html().replace(/#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})([^\w])/g, function(match, group1, group2) {
      return '<span class="color-highlight" style="color: ' + contrastForColor(group1) + '; background: #' + group1 + ';">#' + group1 + '</span>' + group2
    }))
  })
})
