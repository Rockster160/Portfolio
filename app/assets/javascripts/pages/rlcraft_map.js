var RLCraftMap;
function RLCraftSVG() {
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
  }

  svgObj.margin = { top: 10, right: 30, bottom: 30, left: 60 }
  svgObj.width = 1000 - svgObj.margin.left - svgObj.margin.right
  svgObj.height = 1000 - svgObj.margin.top - svgObj.margin.bottom
  svgObj.points = []

  svgObj.x = d3.scaleLinear()
    .domain([-10000, 10000])
    .range([ 0, svgObj.width ])

  svgObj.y = d3.scaleLinear()
    .domain([-10000, 10000])
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
    svgObj.map.insert("circle", ":first-child")
      .attr("class", "distance-circle")
      .attr("r", function() { return svgObj.r(1000) })
      .attr("cx", function() { return svgObj.x(point.x) })
      .attr("cy", function() { return svgObj.y(point.y) })
      .attr("stroke", function() { return "green" })
      .attr("fill", "transparent")
    svgObj.map.insert("circle", ":first-child")
      .attr("class", "distance-circle")
      .attr("r", function() { return svgObj.r(2000) })
      .attr("cx", function() { return svgObj.x(point.x) })
      .attr("cy", function() { return svgObj.y(point.y) })
      .attr("stroke", function() { return "yellow" })
      .attr("fill", "transparent")
    svgObj.map.insert("circle", ":first-child")
      .attr("class", "distance-circle")
      .attr("r", function() { return svgObj.r(3000) })
      .attr("cx", function() { return svgObj.x(point.x) })
      .attr("cy", function() { return svgObj.y(point.y) })
      .attr("stroke", function() { return "orange" })
      .attr("fill", "transparent")
    svgObj.map.insert("circle", ":first-child")
      .attr("class", "distance-circle")
      .attr("r", function() { return svgObj.r(4000) })
      .attr("cx", function() { return svgObj.x(point.x) })
      .attr("cy", function() { return svgObj.y(point.y) })
      .attr("stroke", function() { return "red" })
      .attr("fill", "transparent")
  }

  // Initialize
  svgObj.init()
}

RLCraftSVG.getMap = function() {
  return RLCraftMap || new RLCraftSVG()
}
