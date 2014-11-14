var ready = function() {
  var canvas = document.getElementById("clocks");
  if (canvas) {
    var ctx = canvas.getContext("2d");

    var W = 100;
    var H = 100;

    function draw_face () {
      ctx.clearRect(0, 0, W, H);
      ctx.beginPath();
      ctx.arc(51, 51, 45, 0, 2*Math.PI);
      ctx.lineWidth = 5;
      ctx.stroke();
    }

    function deg_sin (angle) {
      return Math.sin(Math.PI * (angle/180));
    }

    function degrees () {
      var t = new Date();
      var hr = t.getHours() > 12 ? t.getHours() - 12 : t.getHours();
      var sec_deg = (360/60) * t.getSeconds();
      var min_deg = (360/60) * t.getMinutes() + (sec_deg / (12*60));
      var hr_deg = (360/12) * hr + (min_deg / 12);
      return [sec_deg - 90, min_deg - 90, hr_deg - 90];
    }

    function calculateSides (side_c, angle_a) {
      x = deg_sin(90 - angle_a) * side_c
      y = deg_sin(angle_a) * side_c
      return [x + 50, y + 50];
    }

    function draw () {
      draw_face();

      time_deg = degrees();
      sec_hand_sides = calculateSides(35, time_deg[0]);
      min_hand_sides = calculateSides(30, time_deg[1]);
      hr_hand_sides = calculateSides(25, time_deg[2]);

      ctx.beginPath();
      ctx.lineWidth = 6;
      ctx.moveTo(50, 50);
      ctx.lineTo(hr_hand_sides[0], hr_hand_sides[1]);
      ctx.stroke();
      ctx.lineWidth = 4;
      ctx.moveTo(50, 50);
      ctx.lineTo(min_hand_sides[0], min_hand_sides[1]);
      ctx.stroke();
      ctx.lineWidth = 2;
      ctx.moveTo(50, 50);
      ctx.lineTo(sec_hand_sides[0], sec_hand_sides[1]);
      ctx.stroke();
    }

    setInterval(function(){draw();}, 1000);
  }
}

$(document).ready(ready);
$(document).on('page:load', ready);
