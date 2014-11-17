var ready = function() {
  var canvas = document.getElementById("clocks");
  if (canvas) {
    var ctx = canvas.getContext("2d");

    var which_clock = 1;
    var W = canvas.width;
    var H = canvas.height;
    var X = (W/2);
    var Y = (H/2);
    var particles = [];

    $('#clocks').click(function() {
      which_clock += 1;
      if (which_clock == 3) { which_clock = 0 };
      draw();
    });

    canvas.addEventListener('click', function(evt) {
      var mousePos = getMousePos(canvas, evt);
      var amount = 20;
      for (var i=0;i<amount;i++) { particles.push(new createParticle(mousePos.x, mousePos.y, amount)) };
    }, false);
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
      ctx.moveTo(X, Y);
      ctx.lineTo(hr_hand_sides[0], hr_hand_sides[1]);
      ctx.stroke();
      ctx.lineWidth = 3;
      ctx.moveTo(X, Y);
      ctx.lineTo(min_hand_sides[0], min_hand_sides[1]);
      ctx.stroke();
      ctx.lineWidth = 2;
      ctx.moveTo(X, Y);
      ctx.lineTo(sec_hand_sides[0], sec_hand_sides[1]);
      ctx.stroke();
    }

    function drawFace () {
      ctx.beginPath();
      ctx.arc(X, Y, 45, 0, 2*Math.PI);
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
        tick_mark_length = (i*6%30 == 0 ? 38 : 41);
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
      return [x + X, y + Y];
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

      var blankSegment = [5, 38, 80, 112, 155, 187];
      ctx.beginPath();
      // ctx.moveTo((X - 215/2), (Y - 60/2));
      ctx.arc((X - 215/2) + 70, (Y - 60/2) + 20, 3, 0, Math.PI*2);
      ctx.arc((X - 215/2) + 70, (Y - 60/2) + 40, 3, 0, Math.PI*2);
      ctx.fillStyle = "blue";
      ctx.fill();
      ctx.beginPath();
      ctx.arc((X - 215/2) + 144, (Y - 60/2) + 20, 3, 0, Math.PI*2);
      ctx.arc((X - 215/2) + 144, (Y - 60/2) + 40, 3, 0, Math.PI*2);
      ctx.fill();
      for (var i=0;i<6;i++) {
        selectSeg((X - 215/2) + blankSegment[i], (Y - 60/2) + 5, 0);
        drawSevenSeg(i, time[i].toString())
      }
    }

    function selectSeg(x, y, segment) {
      ctx.beginPath();
      ctx.fillStyle = "blue";
      if (segment == "A") { drawSeg(x, y, 0) }
      else if (segment == "B") { drawSeg(x + 24, y + 24, 1) }
      else if (segment == "C") { drawSeg(x + 24, y + 50, 1) }
      else if (segment == "D") { drawSeg(x + 22, y + 52, 2) }
      else if (segment == "E") { drawSeg(x - 2, y + 2, 3) }
      else if (segment == "F") { drawSeg(x - 2, y + 28, 3) }
      else if (segment == "G") { drawSeg(x, y + 26, 4) }
      else {
            ctx.fillStyle = "#DDD";
            drawSeg(x, y, 0); //A - up
            drawSeg(x + 24, y + 24, 1); //B - right
            drawSeg(x + 24, y + 50, 1); //C - right
            drawSeg(x + 22, y + 52, 2); //D - down
            drawSeg(x - 2, y + 2, 3); //E - left
            drawSeg(x - 2, y + 28, 3); //F - left
            drawSeg(x, y + 26, 4); //G - mid
        };
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
      var x = (X - 215/2), y =  (Y - 60/2) + 5;
      if (index == 0) { x += 5; };
      if (index == 1) { x += 38; };
      if (index == 2) { x += 80; };
      if (index == 3) { x += 112; };
      if (index == 4) { x += 155; };
      if (index == 5) { x += 187; };
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
      times = [t.getHours(), t.getMinutes(), t.getSeconds()]
      for ( var i=0;i<times.length;i++ ) {
        piece = times[i].toString(2).split("");
        while (piece.length < 6) {
          piece.unshift("0");
        }
        for ( var j=0;j<piece.length;j++ ) {
          var x = (X - 250/2) + 25 + (j*40);
          var y = 45 + (20*i);
          var circle_color = "";
          if (i == 0) { circle_color = "blue" };
          if (i == 1) { circle_color = "green" };
          if (i == 2) { circle_color = "red" };

          ctx.beginPath();
          ctx.fillStyle = (piece[j] == "0" ? "#DDD" : circle_color);
          ctx.moveTo(x, y);
          // ctx.arc(x, y, 10, 0, Math.PI*2); //Multiple Rows - Change Single to y = 15
          ctx.moveTo(x, 10);
          var radius = (3-i)*5;
          if (piece[j] == "1" || i == 0) { ctx.arc(x, Y, radius, 0, Math.PI*2) }; //Single Row
          ctx.fill();
        }
      }
    }
// ---------------------------- /Binary ----------------------------------------
    function draw () {
      var t = new Date();

      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = "black";
      ctx.fillText("Click Me!", 10, 15);

      if (which_clock == 0) {
        analog(t);
      }
      if (which_clock == 1) {
        digital(t);
      }
      if (which_clock == 2) {
        binary(t);
      }

      if (particles.length > 1) { drawParticle() };
    }

    function createParticle(x, y, amount) {
      this.myX = x;
      this.myY = y;

      this.life = 50;

      this.velX = Math.random()*10 - 5;
      this.velY = -Math.random()*8;

      this.myRad = Math.random()*3+1;
    }

    function drawParticle() {
      for (var t=0;t<particles.length;t++) {
        var par = particles[t];
        ctx.beginPath();

        var grad = ctx.createRadialGradient(par.myX,par.myY,0,par.myX,par.myY,par.myRad);
        grad.addColorStop(0,"red"); //Core
        grad.addColorStop(0.8,"pink"); //Body
        grad.addColorStop(1,"white"); //Background fade

        ctx.fillStyle = grad;
        ctx.arc(par.myX,par.myY,par.myRad,Math.PI*2,false);
        ctx.fill();

        par.velY += 1;
        par.myX += par.velX;
        par.myY += par.velY;
        par.life -= 1;

        if (par.myX > W || par.myX < 0 || par.myY > H || par.life <= 0) { particles.splice(t, 1) };
      }
    }

    function getMousePos(canvas, evt) {
      var rect = canvas.getBoundingClientRect();
      return {
        x: evt.clientX - rect.left,
        y: evt.clientY - rect.top
      };
    }

    draw();
    setInterval(function(){draw();}, 50);
  }
}

$(document).ready(ready);
$(document).on('page:load', ready);
