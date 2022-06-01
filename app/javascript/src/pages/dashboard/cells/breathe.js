(function() {
  Cell.register({
    title: "Breathe",
    onload: function() {
      var createdStyleTag = document.createElement("style");
      createdStyleTag.textContent = (
        "@keyframes breathe {" +
          "0%   { background-size: 100%; }" +
          "20%  { background-size: 2500%; }" +
          "50%  { background-size: 2500%; }" +
          "80%  { background-size: 100%; }" +
          "100% { background-size: 100%; }" +
        "}" +
        ".breathe {" +
          "animation: 12s linear breathe infinite;" +
          "position: absolute;" +
          "top: 0;" +
          "left: 0;" +
          "right: 0;" +
          "bottom: 0;" +
          "background: radial-gradient(circle at center, #3D94F6 0%, transparent 5%);" +
          "background-repeat: no-repeat;" +
          "background-position: center;" +
        "}"
      )
      document.body.appendChild(createdStyleTag)
      var html = '<div class="breathe"></div>'
      this.ele.children(".dash-content").html(html)
      this.ele.children(".dash-content").html(html)
    }
  })
})()
