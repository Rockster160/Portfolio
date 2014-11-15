var ready = function() {
  var canvas = document.getElementById("sparks");
  if (canvas) {
    var ctx = canvas.getContext("2d");

    var W = 250;
    var H = 250;

    var particles = [];
    for (var i=0;i<250;i++) {
      particles.push(new create_particle());
    };

    function create_particle() {
      this.myX = W/2
      this.myY = H/2

      this.velX = Math.random()*4 - 2;
      this.velY = Math.random()*4 - 2;

      this.myRad = Math.random()*10+1;
    }

    function draw() {
      ctx.clearRect(0, 0, W, H);
      ctx.fillStyle = "rgba(255,255,255, 0)";
      ctx.fillRect(0, 0, W, H);
        // ctx.fillStyle = "rgba(255,255,25, 1)";
        // ctx.fillRect(10, 10, (W), 15);

      for (var t=0;t<particles.length;t++) {
        var par = particles[t];
        ctx.beginPath();

        var grad = ctx.createRadialGradient(par.myX,par.myY,0,par.myX,par.myY,par.myRad);
        grad.addColorStop(0,"pink"); //Core
        grad.addColorStop(0.5,"red"); //Body
        grad.addColorStop(1,"white"); //Background fade

        ctx.fillStyle = grad;
        ctx.arc(par.myX,par.myY,par.myRad,Math.PI*2,false);
        ctx.fill();

        par.myX += par.velX;
        par.myY += par.velY;

        if (par.myX > W) {par.myX = 0;};
        if (par.myX < 0) {par.myX = W;};
        if (par.myY > H) {par.myY = 0;};
        if (par.myY < 0) {par.myY = H;};
      }
    }

    setTimeout(function () {
        var x = 0;
        var intervalID = window.setInterval(function () {

           draw();

           if (++x === 4000) {
               window.clearInterval(intervalID);
           }
        }, 40);
    }, 500);
  }
}

$(document).ready(ready);
$(document).on('page:load', ready);
