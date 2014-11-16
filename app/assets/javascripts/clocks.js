// Clock animation - on page load clock fades in after hidden
$( window ).load(function() {
  $('canvas').hide().fadeIn('slow');
});

var ready = function() {
  var canvas = document.getElementById("clocks");
  if (canvas) {
    var ctx = canvas.getContext("2d");

    var which_clock = 1;
    var W = 250;
    var H = 100;

    $('#clocks').click(function() {
      console.log('Clicked');
      which_clock += 1;
      if (which_clock == 3) {which_clock = 0};
      draw();
      // clocks get added a class that triggers
      // the css animation 
      // then the time the animation ends
      // is the time that then the class is removed
      // via a set timeout function so that
      // upon another click the clock will keep doing
      // the animations per clock change 
      $('#clocks').addClass('clock_animations');
      setTimeout(function(){
        $('#clocks').removeClass('clock_animations');
      },500);
      
    })
// ----------------------------- Analog ----------------------------------------
    function analog (t) {
      drawFace();
      drawNumbers();

      time_deg = degrees(t);
      sec_hand_sides = calculateSides(40, time_deg[0]);
      min_hand_sides = calculateSides(32, time_deg[1]);
      hr_hand_sides = calculateSides(25, time_deg[2]);

      ctx.beginPath();
      ctx.lineWidth = 5;
      ctx.moveTo(50, 50);
      ctx.lineTo(hr_hand_sides[0], hr_hand_sides[1]);
      ctx.stroke();
      ctx.lineWidth = 3;
      ctx.moveTo(50, 50);
      ctx.lineTo(min_hand_sides[0], min_hand_sides[1]);
      ctx.stroke();
      ctx.lineWidth = 2;
      ctx.moveTo(50, 50);
      ctx.lineTo(sec_hand_sides[0], sec_hand_sides[1]);
      ctx.stroke();
    }

    function drawFace () {
      ctx.clearRect(0, 0, W, H);
      ctx.beginPath();
      ctx.arc(50, 50, 45, 0, 2*Math.PI);
      ctx.lineWidth = 4;
      ctx.fillStyle = "white";
      ctx.fill();
      ctx.stroke();
      ctx.closePath();
    }

    function drawNumbers () {
      ctx.beginPath();
      ctx.fillStyle = "black";
      for (var i=0;i<12;i++) {
        sides = calculateSides(34, ((i + 1) * 30 - 90));
        if (i < 9) {sides[0] += 2};
        ctx.fillText((i+1).toString(), sides[0] - 5, sides[1] + 4);
      }
      ctx.lineWidth = 1;
      ctx.moveTo(50, 50);
      for (var i=0;i<60;i++) {
        tick_mark_length = (i*6%30 == 0 ? 38 : 41)
        tick_mark_start = calculateSides(tick_mark_length, i*6);
        tick_mark_end = calculateSides(45, i*6);
        ctx.moveTo(tick_mark_start[0], tick_mark_start[1]);
        ctx.lineTo(tick_mark_end[0], tick_mark_end[1]);
        ctx.stroke();
      }
    }

    function calculateSides (side_c, angle_a) {
      x = degSin(90 - angle_a) * side_c
      y = degSin(angle_a) * side_c
      return [x + 50, y + 50];
    }

    function degSin (angle) {
      return Math.sin(Math.PI * (angle/180));
    }

    function degrees (t) {
      var hr = t.getHours() > 12 ? t.getHours() - 12 : t.getHours();
      var sec_deg = (360/60) * t.getSeconds();
      var min_deg = (360/60) * t.getMinutes() + (sec_deg / 60);
      var hr_deg = (360/12) * hr + (min_deg / 12);
      return [sec_deg - 90, min_deg - 90, hr_deg - 90];
    }
// --------------------------- /Analog -----------------------------------------
// --------------------------- Digital -----------------------------------------
    function digital (t) {
      no_military = t.getHours() > 12 ? t.getHours() - 12 : t.getHours();
      str_hour = no_military.toString()
      str_minute = t.getMinutes().toString();
      str_second = t.getSeconds().toString();
      hr = (str_hour.length < 2 ? "0" : "") + str_hour;
      mn = (str_minute.length < 2 ? "0" : "") + str_minute;
      sc = (str_second.length < 2 ? "0" : "") + str_second;
      time = (hr+mn+sc).split("");

      ctx.clearRect(0, 0, W, H);
      var blankSegment = [5, 38, 80, 112, 155, 187];
      for (var i=0;i<6;i++) {
        selectSeg(blankSegment[i], 5, 0);
        drawSevenSeg(i, time[i].toString())
      }
    }

    function selectSeg(x, y, segment) {
      ctx.beginPath();
      ctx.fillStyle = "blue";
      switch (segment) {
        case "A":
          drawSeg(x, y, 0); //A - up
          break;
        case "B":
          drawSeg(x + 24, y + 24, 1); //B - right
          break;
        case "C":
          drawSeg(x + 24, y + 50, 1); //C - right
          break;
        case "D":
          drawSeg(x + 22, y + 52, 2); //D - down
          break;
        case "E":
          drawSeg(x - 2, y + 2, 3); //E - left
          break;
        case "F":
          drawSeg(x - 2, y + 28, 3); //F - left
          break;
        case "G":
          drawSeg(x, y + 26, 4); //G - mid
          break;
        default: {
            ctx.fillStyle = "#EEE"
            drawSeg(x, y, 0); //A - up
            drawSeg(x + 24, y + 24, 1); //B - right
            drawSeg(x + 24, y + 50, 1); //C - right
            drawSeg(x + 22, y + 52, 2); //D - down
            drawSeg(x - 2, y + 2, 3); //E - left
            drawSeg(x - 2, y + 28, 3); //F - left
            drawSeg(x, y + 26, 4); //G - mid
        }
      }
      ctx.fillStyle = "black";
    }

    function drawSeg (x, y, index) {
      ctx.moveTo(x, y);
      var up = [[4, -1], [18, -1], [22, 0], [18, 4], [4, 4]];
      var right = [], down = [], left = []
      for ( i = 0; i < up.length; i++ ) {
        down.push([up[i][0] * -1, up[i][1] * -1]);
        right.push([up[i][1] * -1, up[i][0] * -1]);
        left.push([up[i][1], up[i][0]]);
      }
      var mid = [[4, -3], [18, -3], [22, 0], [18, 3], [4, 3]];
      if (index == 0) { drawLine(x, y, up); };
      if (index == 1) { drawLine(x, y, right); };
      if (index == 2) { drawLine(x, y, down); };
      if (index == 3) { drawLine(x, y, left); };
      if (index == 4) { drawLine(x, y, mid); };
    }

    function drawLine (x, y, array) {
      for (var i=0;i<array.length;i++) {
        ctx.lineTo(x + array[i][0], y + array[i][1]);
      }
      ctx.closePath();
      ctx.fill();
    }

    function drawSevenSeg (index, number) {
      var x = 0, y = 5;
      if (index == 0) { x = 5; };
      if (index == 1) { x = 38; };
      if (index == 2) { x = 80; };
      if (index == 3) { x = 112; };
      if (index == 4) { x = 155; };
      if (index == 5) { x = 187; };
      // 0, 2, 3, 5, 6, 7, 8, 9 - A
      if (number == 0 || number == 2 || number == 3 || number == 5 || number == 6 || number == 7 || number == 8 || number == 9) {
        selectSeg(x, y, "A");
      }
      // 0, 1, 2, 3, 4, 7, 8, 9 - B
      if (number == 0 || number == 1 || number == 2 || number == 3 || number == 4 || number == 7 || number == 8 || number == 9) {
        selectSeg(x, y, "B");
      }
      // 0, 1, 3, 4, 5, 6, 8, 9 - C
      if (number == 0 || number == 1 || number == 3 || number == 4 || number == 5 || number == 6 || number == 7 || number == 8 || number == 9) {
        selectSeg(x, y, "C");
      }
      // 0, 2, 3, 5, 6, 8, 9 - D
      if (number == 0 || number == 2 || number == 3 || number == 5 || number == 6 || number == 8 || number == 9) {
        selectSeg(x, y, "D");
      }
      // 0, 2, 6, 8 - E
      if (number == 0 || number == 4 || number == 5 || number == 6 || number == 8 || number == 9) {
        selectSeg(x, y, "E");
      }
      // 0, 4, 5, 6, 8, 9 - F
      if (number == 0 || number == 2 || number == 6 || number == 8) {
        selectSeg(x, y, "F");
      }
      // 2, 3, 4, 5, 6, 8, 9 - G
      if (number == 2 || number == 3 || number == 4 || number == 5 || number == 6 || number == 8 || number == 9) {
        selectSeg(x, y, "G");
      }
    }
// --------------------------- /Digital ----------------------------------------
// ---------------------------- Binary -----------------------------------------
    function binary (t) {
      ctx.clearRect(0, 0, W, H);
      times = [t.getHours(), t.getMinutes(), t.getSeconds()]
      for (i=0;i<times.length;i++) {
        piece = times[i].toString(2).split("");
        while (piece.length < 6) {
          piece.unshift("0");
        }
        ctx.fillText(piece.join(""), 10, 10 + (i*10));
      }
    }
// ---------------------------- /Binary ----------------------------------------
    function draw () {
      var t = new Date();
      if (which_clock == 0) {
        analog(t);
      }
      if (which_clock == 1) {
        digital(t);
      }
      if (which_clock == 2) {
        binary(t);
      }
    }

    draw();
    setInterval(function(){draw();}, 100);
  }
}

$(document).ready(ready);
$(document).on('page:load', ready);
