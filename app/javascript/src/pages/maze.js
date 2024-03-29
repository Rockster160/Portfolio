$(document).ready(function() {
  if ($(".ctr-mazes.act-show").length == 0) { return }
  movePlayer = function(direction) {
    var rel_coords = relativeCoordsFromDirection(direction), player_cell = $(".cell-player"), player_coords = getCellCoords(player_cell), new_coord = [rel_coords[0] + player_coords[0], rel_coords[1] + player_coords[1]];
    var new_cell = getCellAtCoord(new_coord[0], new_coord[1]);

    if (new_cell.hasClass("cell-open")) {
      player_cell.removeClass("cell-player").addClass("cell-open");
      new_cell.addClass("cell-player").removeClass("cell-open");
    } else if (new_cell.hasClass("cell-finish")) {
      player_cell.removeClass("cell-player").addClass("cell-open");
      new_cell.addClass("cell-player").removeClass("cell-finish");
      var victory_html = $("<div>", {class: "maze-victory"}).html("Victory!");
      $("#maze").before(victory_html);
    } else {
      new_cell.css({backgroundColor: "red"});
      new_cell.animate({backgroundColor: "black"}, 500);
    }
  }

  getCellAtCoord = function(x, y) {
    var rows = $('.maze-row'), row_at_coord = $(rows[y]), cell_at_coord = $(row_at_coord.children()[x]);
    return cell_at_coord;
  }

  getCellCoords = function(cell) {
    var $cell = $(cell), $cell_x = $cell.index(), $cell_y = $cell.parent().index();
    return [$cell_x, $cell_y];
  }

  relativeCoordsFromDirection = function(direction) {
    switch(direction) {
      case "up":
      return [0, -1];
      break;
      case "down":
      return [0, 1];
      break;
      case "left":
      return [-1, 0];
      break;
      case "right":
      return [1, 0];
      break;
    }
  }

  $(document).keydown(function(e) {
    switch(e.which) {
      case keyEvent("UP"):
      case keyEvent("W"):
      movePlayer("up");
      break;
      case keyEvent("DOWN"):
      case keyEvent("A"):
      movePlayer("down");
      break;
      case keyEvent("LEFT"):
      case keyEvent("S"):
      movePlayer("left");
      break;
      case keyEvent("RIGHT"):
      case keyEvent("D"):
      movePlayer("right");
      break;
    }
  })

})
