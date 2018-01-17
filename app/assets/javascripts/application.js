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

seconds = second = function(count) { return 1000 * count || 1 }
minutes = minute = function(count) { return 60 * seconds(count) }
hours = hour = function(count) { return 60 * minutes(count) }
days = day = function(count) { return 24 * hours(count) }

function parseParams(str) {
  var pieces = str.split("&"), data = {}, i, parts;
  for (i = 0; i < pieces.length; i++) {
    parts = pieces[i].split("=");
    if (parts.length < 2) {
      parts.push("");
    }
    data[decodeURIComponent(parts[0])] = decodeURIComponent(parts[1]);
  }
  return data;
}
params = parseParams(window.location.search.slice(1))
