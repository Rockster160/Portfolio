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
//= require command_proposal
//= require gmaps/google
//= require_tree .
//= stub support/colorpicker.js
//= stub support/pell.js
//= stub support/particles.js
//= stub support/particles_json.js
//= stub support/touch_punch.js
//= stub support/parser.js
//= stub support/gcode_splitter.js
//= stub pages/random/dnd.js

// import "*"
//= link_tree ../images
//= link_directory ../javascripts .js
//= link_directory ../stylesheets .css
//= link_directory ../stylesheets .scss
//= link favicon/browserconfig.xml.erb
//= link_tree ../builds

import "./preimports.js"
// import "jquery-ui" // https://gorails.com/episodes/how-to-use-jquery-with-esbuild @ 10:30

// import "./components"
// import "./1a_pageready.js"
// import "./code_formatting.js"

import "./cable.js"
import "./lists/list_channel.js"
import "./lists/list.js"
import "./lists/schedule.js"
import "./lists/list_item_channel.js"
import "./cards/queue.js"
import "./cards/cardZone.js"
import "./cards/cardGame.js"
import "./cards/card.js"
import "./code_formatting.js"
import "./components/array.js"
import "./components/countdown.js"
import "./components/helpers.js"
import "./flashes.js"
import "./support/touch_punch.js"
import "./support/words_to_numbers.js"
import "./support/multi_key_detection.js"
import "./support/searchable.js"
import "./support/colorpicker.js"
import "./support/particles_json.js"
import "./support/pathfinding.js"
import "./support/gcode_splitter.js"
import "./support/pell.js"
import "./support/particles.js"
import "./support/parser.js"
import "./preimports.js"
import "./push_api.js"
import "./1a_pageready.js"
import "./application.js"
import "./pages/rlcraft_map.js"
import "./pages/functions.js"
import "./pages/bowling.js"
import "./pages/spinner.js"
import "./pages/dashboard/demo/snake.js"
import "./pages/dashboard/demo/rps.js"
import "./pages/dashboard/demo/month.js"
import "./pages/dashboard/demo/rand.js"
import "./pages/dashboard/cells/notes.js"
import "./pages/dashboard/cells/reminders.js"
import "./pages/dashboard/cells/grocery.js"
import "./pages/dashboard/cells/weather.js"
import "./pages/dashboard/cells/_server_requests.js"
import "./pages/dashboard/cells/todo.js"
import "./pages/dashboard/cells/timers.js"
import "./pages/dashboard/cells/github.js"
import "./pages/dashboard/cells/_time.js"
import "./pages/dashboard/cells/uptime.js"
import "./pages/dashboard/cells/printer.js"
import "./pages/dashboard/cells/calendar.js"
import "./pages/dashboard/cells/recent.js"
import "./pages/dashboard/cells/fitness.js"
import "./pages/dashboard/_text.js"
import "./pages/dashboard/_dashboard.js"
import "./pages/dashboard/_reconnecting_websocket.js"
import "./pages/dashboard/_cells.js"
import "./pages/rlcraft.js"
import "./pages/homepage.js"
import "./pages/clocks.js"
import "./pages/maze.js"
import "./pages/svg.js"
import "./pages/random/dnd.js"
import "./pages/buckets.js"
import "./pages/map.js"
import "./pages/fade_colors.js"
import "./pages/anonicon.js"
import "./pages/little_world/character_builder.js"
import "./pages/little_world/character_movement.js"
import "./pages/little_world/player.js"
import "./pages/little_world/little_world_controls.js"
import "./pages/calc.js"
import "./pages/monster.js"
import "./pages/email.js"
import "./modals.js"
import "./channels/little_world_channel.js"
import "./channels/logger_channel.js"
import "./channels/nfc_channel.js"

console.log("app.js");

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

keyIsPressed = function(evt, key) {
  return evt.which == keyEvent(key)
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
