$(document).ready(function() {
  if (window.hasOwnProperty("d3")) {
    PaymentCalendar = null
    var containerSelector = "#calendar-svg-wrapper"

    Array.range = function(start, end) {
      var arr = []
      while(start <= end) {
        arr.push(start)
        start++
      }
      return arr
    }
    // Create our number formatter.
    var currencyFormatter = new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: 'USD',
    })
    var valueColor = function(val) {
      if (val > 0) { return "green" }
      if (val < 0) { return "red" }
    }

    PC_SVG = function(start_value, dataset) {
      var svgObj = this

      svgObj.init = function() {
        var today = new Date()
        var date = today.getDate()
        var start_day = date
        function getDaysInMonth(m, y) {
          return (m === 2) ? (!((y % 4) || (!(y % 100) && (y % 400))) ? 29 : 28) : 30 + ((m + (m >> 3)) & 1)
        }
        var count_days_in_month = getDaysInMonth(today.getMonth(), today.getYear())
        var ordered_dates = Array.range(1, count_days_in_month).sort(function(a, b) {
          if (a < start_day) { a += 100 }
          if (b < start_day) { b += 100 }
          if (a < b) { return -1 }
          if (a > b) { return 1 }
          return 0
        })
        dataset = svgObj.formatDataset(dataset, ordered_dates)

        var data_amounts = dataset.map(function(d) { return d.y })
        svgObj.minY = Math.min.apply(Math, [].concat(data_amounts, [0]))
        svgObj.maxY = Math.max.apply(Math, data_amounts)
        svgObj.margin = { top: 50, right: 50, bottom: 50, left: 50 }
        svgObj.width = $(containerSelector).innerWidth() - svgObj.margin.left - svgObj.margin.right
        svgObj.height = $(containerSelector).innerHeight() - svgObj.margin.top - svgObj.margin.bottom

        // Create a tooltip object to display info
        svgObj.tooltip = d3.select(containerSelector)
          .append("div")
          .attr("class", "calendar-tooltip")
          .style("opacity", 0)

        // append the svg object to the body of the page
        svgObj.svg = d3.select(containerSelector)
          .append("svg")
          .attr("width", svgObj.width + svgObj.margin.left + svgObj.margin.right)
          .attr("height", svgObj.height + svgObj.margin.top + svgObj.margin.bottom)
          .attr("transform", "translate(" + svgObj.margin.left + "," + svgObj.margin.top + ")")

        // https://www.d3-graph-gallery.com/graph/custom_axis.html
        svgObj.xScale = d3.scaleBand()
          .domain(ordered_dates)
          .range([ svgObj.margin.left, svgObj.width + svgObj.margin.right ])
          .padding([1])

        svgObj.yScale = d3.scaleLinear()
          .domain([svgObj.maxY, svgObj.minY]) // This should be determined using the high/low values of the schedules
          .range([ svgObj.margin.top, svgObj.height + svgObj.margin.bottom ])

        svgObj.line = d3.line()
          .x(function(d, i) { return svgObj.xScale(d.x) })
          .y(function(d) { return svgObj.yScale(d.y) })
          .curve(d3.curveMonotoneX)

        // Add X axis
        svgObj.svg.append("g")
          .attr("transform", "translate(" + 0 + "," + (svgObj.height + svgObj.margin.bottom) + ")")
          .call(d3.axisBottom(svgObj.xScale).tickSize(-svgObj.height))

        // Add Y axis
        svgObj.svg.append("g")
          .attr("transform", "translate(" + svgObj.margin.left + "," + 0 + ")")
          .call(d3.axisLeft(svgObj.yScale).tickSize(-svgObj.width))

        // Add 0 marker
        svgObj.svg.append("line")
          .attr("x1", svgObj.margin.left)
          .attr("y1", svgObj.yScale(0))
          .attr("x2", svgObj.width + svgObj.margin.right)
          .attr("y2", svgObj.yScale(0))
          .style("stroke", "red")
          .style("stroke-width", 1)

        // Add current day marker
        svgObj.svg.append("line")
          .attr("x1", svgObj.xScale(date))
          .attr("y1", svgObj.margin.bottom)
          .attr("x2", svgObj.xScale(date))
          .attr("y2", svgObj.height + svgObj.margin.top)
          .style("stroke", "green")
          .style("stroke-width", 1)

        svgObj.addDataset = function(dataset) {
          svgObj.svg.selectAll("data-line").remove()
          svgObj.svg.selectAll("data-dot").remove()
          // Line
          svgObj.svg.append("path")
            .datum(dataset)
            .attr("class", "data-line")
            .attr("d", svgObj.line)

          // Points
          svgObj.svg.selectAll(".dot")
            .data(dataset)
            .enter().append("circle")
            .attr("class", "data-dot")
            .attr("x", function(d) { return d.x })
            .attr("y", function(d) { return d.y })
            .attr("points", function(d) { return JSON.stringify(d.points) })
            .attr("cx", function(d, i) { return svgObj.xScale(d.x) })
            .attr("cy", function(d) { return svgObj.yScale(d.y) })
            .attr("r", 5)
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

          svgObj.pointTooltipHTML = function(dot) {
            var str = "<h4>" + dot.x + "<h4>"
            str += "<table>"
            dot.points.forEach(function(point) {
              str += "<tr>"
              str += "<td class=\"name\">" + point.name + "</td>"
              str += "<td class=\"cost " + valueColor(point.y) + "\">" + currencyFormatter.format(point.y) + "</td>"
              str += "</tr>"
            })
            str += "<tr>"
            str += "<td class=\"name\">" + "Total" + "</td>"
            str += "<td class=\"cost " + valueColor(dot.y) + "\">" + currencyFormatter.format(dot.y) + "</td>"
            str += "</tr>"
            str += "</table>"
            return str
          }
        }

        svgObj.addDataset(dataset)

        return this
      }

      svgObj.formatDataset = function(dataset, ordered_dates) {
        var running_total = start_value
        var newDataset = {}
        dataset.sort(function(a, b) {
          var ax = ordered_dates.indexOf(a.x)
          var bx = ordered_dates.indexOf(b.x)
          if (ax < bx) { return -1 }
          if (ax > bx) { return 1 }
          return 0
        }).forEach(function(point) {
          var old_point = newDataset[point.x] || {x: point.x, y: 0, points: []}

          running_total += point.y
          old_point.y = running_total
          old_point.points.push(point)
          newDataset[point.x] = old_point
        })

        return Object.values(newDataset).sort(function(a, b) {
          var ax = ordered_dates.indexOf(a.x)
          var bx = ordered_dates.indexOf(b.x)
          if (ax < bx) { return -1 }
          if (ax > bx) { return 1 }
          return 0
        })
      }
    }
  }
})
