$(document).ready(function() {
  if (window.hasOwnProperty("d3")) {
    RLCraftMap = null

    RLCraftSVG = function() {
      var svgObj = this

      svgObj.init = function() {
        RLCraftMap = svgObj

        // Create a tooltip object to display info
        svgObj.tooltip = d3.select("#rlc-svg")
          .append("div")
          .attr("class", "rlc-tooltip")
          .style("opacity", 0)

        // append the svg object to the body of the page
        svgObj.map = d3.select("#rlc-svg")
          .append("svg")
            .attr("width", svgObj.width + svgObj.margin.left + svgObj.margin.right)
            .attr("height", svgObj.height + svgObj.margin.top + svgObj.margin.bottom)
            .call(d3.zoom().on("zoom", function() {
              svgObj.map.attr("transform", d3.event.transform)
            }))
            .append("g")
            .attr("transform", "translate(" + svgObj.margin.left + "," + svgObj.margin.top + ")")

        // Add X axis
        svgObj.map.append("g")
          .attr("transform", "translate(" + 0 + "," + svgObj.height / 2 + ")")
          .call(d3.axisBottom(svgObj.x))

        // Add Y axis
        svgObj.map.append("g")
          .attr("transform", "translate(" + svgObj.width / 2 + "," + 0 + ")")
          .call(d3.axisLeft(svgObj.y))

        // North label
        svgObj.map.append("text")
          .attr("dx", svgObj.x(-400))
          .attr("dy", svgObj.y(-10300))
          .style("font-size", 48)
          .style("fill", "red")
          .text("N")

        // South label
        svgObj.map.append("text")
          .attr("dx", svgObj.x(-250))
          .attr("dy", svgObj.y(10700))
          .style("font-size", 32)
          .style("fill", "blue")
          .text("S")

        // East label
        svgObj.map.append("text")
          .attr("dx", svgObj.x(10400))
          .attr("dy", svgObj.y(250))
          .style("font-size", 32)
          .style("fill", "orange")
          .text("E")

        // West label
        svgObj.map.append("text")
          .attr("dx", svgObj.x(-11000))
          .attr("dy", svgObj.y(250))
          .style("font-size", 32)
          .style("fill", "green")
          .text("W")
      }

      svgObj.margin = { top: 50, right: 50, bottom: 50, left: 50 }
      svgObj.width = 1000 - svgObj.margin.left - svgObj.margin.right
      svgObj.height = 1000 - svgObj.margin.top - svgObj.margin.bottom
      svgObj.points = []

      svgObj.x = d3.scaleLinear()
        .domain([-10000, 10000])
        .range([ 0, svgObj.width ])

      svgObj.y = d3.scaleLinear()
        .domain([10000, -10000])
        .range([ svgObj.height, 0])

      svgObj.r = d3.scaleLinear()
        .domain([-10000, 10000])
        .range([ -svgObj.width, svgObj.width ])

      svgObj.pointTooltipHTML = function(point) {
        var str = ""
        if (point.title) { str = str + "<h4>" + point.title + "</h4>" }
        if (point.description) { str = str + "<i>" + point.description + "</i>" }
        str = str + "<small>(" + point.x + ", " +  point.y + ")</small>"
        return str
      }

      svgObj.remove_points = function(points) {
        points.forEach(function(point) {
          $("[map_id=" + point.id + "]").remove()
        })
      }

      svgObj.add_points = function(points) {
        var point = svgObj.map.append("g")
          .selectAll("dot")
          .data(points)
          .enter()
        point.append("circle")
          .attr("r", 5)
          .attr("cx", function(d) { return svgObj.x(d.x) })
          .attr("cy", function(d) { return svgObj.y(d.y) })
          .attr("map_id", function(d) { return d.id })
          .attr("map_x", function(d) { return d.x })
          .attr("map_y", function(d) { return d.y })
          .attr("rlc-color", function(d) { return d.type })
          .on("mouseover", function(d) {
             svgObj.tooltip.transition()
               .duration(200)
               .style("opacity", 0.9)
             svgObj.tooltip.html(svgObj.pointTooltipHTML(d))
               .style("left", (d3.event.pageX) + "px")
               .style("top", (d3.event.pageY - 28) + "px")
           })
           .on("mouseout", function(d) {
             svgObj.tooltip.transition()
               .duration(500)
               .style("opacity", 0)
           })
           .on("click", svgObj.selectPoint)

        // TODO: Connect waypoint to nearby waypoints
      }

      svgObj.drawCircle = function(center, rad, color) {
        svgObj.map.insert("circle", ":first-child")
          .attr("class", "distance-circle")
          .attr("r", function() { return svgObj.r(rad) })
          .attr("cx", function() { return svgObj.x(center.x) })
          .attr("cy", function() { return svgObj.y(center.y) })
          .attr("stroke", color)
          .attr("fill", color)
          .style("opacity", 0.1)
      }

      svgObj.selectPoint = function(point) {
        var circle = this
        $(".edit-form").removeClass("hidden")
        $("circle.selected").removeClass("selected")
        $(circle).addClass("selected")

        $('input[name="id"]').val(point.id)
        $('input[name="location[x_coord]"]').val(point.x)
        $('input[name="location[y_coord]"]').val(point.y)
        $('input[name="location[title]"]').val(point.title)
        $('select[name="location[location_type]"]').val(point.type)
        $('textarea[name="location[description]"]').val(point.description)

        console.log("Origin: ", point.x, point.y);

        $("circle.distance-circle").remove()
        svgObj.drawCircle({x: point.x, y: point.y}, 1000, "green")
        svgObj.drawCircle({x: point.x, y: point.y}, 2000, "yellow")
        svgObj.drawCircle({x: point.x, y: point.y}, 3000, "orange")
        svgObj.drawCircle({x: point.x, y: point.y}, 4000, "red")
      }

      // Initialize
      svgObj.init()
    }

    RLCraftSVG.getMap = function() {
      return RLCraftMap || new RLCraftSVG()
    }

    rlcraftSetup()
  }
})
