$(document).ready(function() {
  rlCraftMap = new RLCraftSVG()

  rlCraftMap.add_points([{x: 5000, y: 3000, type: "waystone", title: "The End", description: "Custom waystone next to the end"}, {x: 2444, y: -6983}])
  rlCraftMap.add_points([{x: 1123, y: 42, type: "waystone", title: "Mordor", description: "Wil's house."}])
})

function RLCraftSVG() {
  var svgObj = this

  svgObj.init = function() {
    // Create a tooltip object to display info
    svgObj.tooltip = d3.select("#rlcraft-svg")
      .append("div")
      .attr("class", "rlcraft-tooltip")
      .style("opacity", 0)

    // append the svg object to the body of the page
    svgObj.map = d3.select("#rlcraft-svg")
      .append("svg")
        .attr("width", svgObj.width + svgObj.margin.left + svgObj.margin.right)
        .attr("height", svgObj.height + svgObj.margin.top + svgObj.margin.bottom)
      .append("g")
        .attr("transform", "translate(" + svgObj.margin.left + "," + svgObj.margin.top + ")");

    // Add X axis
    svgObj.map.append("g")
      .attr("transform", "translate(" + 0 + "," + svgObj.height / 2 + ")")
      .call(d3.axisBottom(svgObj.x));

    // Add Y axis
    svgObj.map.append("g")
      .attr("transform", "translate(" + svgObj.width / 2 + "," + 0 + ")")
      .call(d3.axisLeft(svgObj.y));
  }

  svgObj.margin = { top: 10, right: 30, bottom: 30, left: 60 }
  svgObj.width = 1000 - svgObj.margin.left - svgObj.margin.right
  svgObj.height = 1000 - svgObj.margin.top - svgObj.margin.bottom
  svgObj.points = []

  svgObj.x = d3.scaleLinear()
    .domain([-10000, 10000])
    .range([ 0, svgObj.width ]);

  svgObj.y = d3.scaleLinear()
    .domain([-10000, 10000])
    .range([ svgObj.height, 0]);

  svgObj.pointTooltipHTML = function(point) {
    var str = ""
    if (point.title) { str = str + "<h4>" + point.title + "</h4>" }
    if (point.description) { str = str + "<i>" + point.description + "</i>" }
    str = str + "<small>(" + point.x + ", " +  point.y + ")</small>"
    return str
  }

  svgObj.pointTooltipColor = function(point) {
    var color = "#000"
    if (point.type == "waystone") { color = "#CCC" }

    return color
  }

  svgObj.add_points = function(points) {
    var point =  svgObj.map.append("g")
      .selectAll("dot")
      .data(points)
      .enter()
    point.append("circle")
      .attr("r", 5)
      .attr("cx", function (d) { return svgObj.x(d.x); } )
      .attr("cy", function (d) { return svgObj.y(d.y); } )
      .style("fill", function (d) { return svgObj.pointTooltipColor(d); } )
      .on("mouseover", function(d) {
         svgObj.tooltip.transition()
           .duration(200)
           .style("opacity", .9);
         svgObj.tooltip.html(svgObj.pointTooltipHTML(d))
           .style("left", (d3.event.pageX) + "px")
           .style("top", (d3.event.pageY - 28) + "px");
       })
       .on("mouseout", function(d) {
         svgObj.tooltip.transition()
           .duration(500)
           .style("opacity", 0);
       });

     svgObj.points.push(point)

    // TODO: Connect waypoint to nearby waypoints
  }

  // Initialize
  svgObj.init()
}
