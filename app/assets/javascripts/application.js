// This is a manifest file that'll be compiled into application.js, which will include all the files
// listed below.
//
// Any JavaScript/Coffee file within this directory, lib/assets/javascripts, vendor/assets/javascripts,
// or vendor/assets/javascripts of plugins, if any, can be referenced here using a relative path.
//
// It's not advisable to add code directly here, but if you do, it'll appear at the bottom of the
// compiled file.
//
// Read Sprockets README (https://github.com/sstephenson/sprockets#sprockets-directives) for details
// about supported directives.
//
//= require jquery
//= require jquery_ujs
//= require jquery-ui
//= require underscore
//= require gmaps/google
//= require_tree .
//= stub support/colorpicker.js
//= stub support/particles.js
//= stub support/particles_json.js
//= stub support/touch_punch.js
//= stub support/parser.js

// http://keycode.info
keyEvent = function(char) {
  var upChar = char.toUpperCase()
  switch(upChar) {
    case "ENTER":
      return 13;
    case "TAB":
      return 9;
    case "SPACE":
      return 32;
    case "ESC":
      return 27;
    case "LEFT":
      return 37;
    case "UP":
      return 38;
    case "DOWN":
      return 40;
    case "RIGHT":
      return 39;
    default:
      return char.charCodeAt(0)
  }
}
