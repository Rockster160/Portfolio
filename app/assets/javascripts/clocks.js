var ready = function() {
  var canvas = document.getElementById("clocks");
  if (canvas) {
    var ctx = canvas.getContext("2d");

    var W = 100;
    var H = 100;

    function drawFace () {
      ctx.clearRect(0, 0, W, H);
      ctx.beginPath();
      t = new Date();
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
        sides = calculateSides(35, ((i + 1) * 30 - 90));
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

    function degSin (angle) {
      return Math.sin(Math.PI * (angle/180));
    }

    function degrees () {
      var t = new Date();
      var hr = t.getHours() > 12 ? t.getHours() - 12 : t.getHours();
      var sec_deg = (360/60) * t.getSeconds();
      var min_deg = (360/60) * t.getMinutes() + (sec_deg / 60);
      var hr_deg = (360/12) * hr + (min_deg / 12);
      return [sec_deg - 90, min_deg - 90, hr_deg - 90];
    }

    function calculateSides (side_c, angle_a) {
      x = degSin(90 - angle_a) * side_c
      y = degSin(angle_a) * side_c
      return [x + 50, y + 50];
    }

    function draw () {
      drawFace();
      drawNumbers();

      time_deg = degrees();
      sec_hand_sides = calculateSides(40, time_deg[0]);
      min_hand_sides = calculateSides(32, time_deg[1]);
      hr_hand_sides = calculateSides(25, time_deg[2]);

      ctx.beginPath();
      ctx.lineWidth = 6;
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
    draw();
    setInterval(function(){draw();}, 1000);
  }
}

$(document).ready(ready);
$(document).on('page:load', ready);
