$(document).ready(function() {
  if (window.hasOwnProperty("d3")) {
    PaymentCalendar = null
    var containerSelector = "#calendar-svg-wrapper"
    var start_value = 2628.41
    var start_day = 10

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

    PC_SVG = function() {
      var svgObj = this

      svgObj.init = function(dataset) {
        var today = new Date()
        var date = today.getDate()
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
          .call(d3.axisBottom(svgObj.xScale))

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

        // Add Y axis
        svgObj.svg.append("g")
          .attr("transform", "translate(" + svgObj.margin.left + "," + 0 + ")")
          .call(d3.axisLeft(svgObj.yScale))

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


      // Initialize

      var dataset = [
        { name: "Payroll",          x: 10, y: 2540.66  },
        { name: "Payroll",          x: 25, y: 2540.66  },

        { name: "Digital Ocean",    x: 1,  y: -20.30   },
        { name: "Quip",             x: 3,  y: -10.00   },
        { name: "Power",            x: 4,  y: -60.00   },
        { name: "Vivint (Service)", x: 8,  y: -41.47   },
        { name: "Gas",              x: 10, y: -90.00   },
        { name: "Trash",            x: 14, y: -51.00   },
        { name: "T-Mobile",         x: 16, y: -65.86   },
        { name: "CrunchyRoll",      x: 17, y: -7.99    },
        { name: "Comcast",          x: 19, y: -84.99   },
        { name: "Progressive",      x: 19, y: -87.85   },
        { name: "Primerica",        x: 20, y: -24.59   },
        { name: "Sewage",           x: 27, y: -25.00   },
        { name: "Water",            x: 28, y: -41.50   },
        { name: "John Hancock",     x: 28, y: -46.36   },
        { name: "Intermountain",    x: 28, y: -93.74   },

        { name: "Apple",            x: 7,  y: -400.00  },
        { name: "IKEA",             x: 2,  y: -250.00  },
        { name: "iPhone (R)",       x: 3,  y: -0.00    },
        { name: "iPhone (K)",       x: 3,  y: -0.00    },
        { name: "Vivint",           x: 8,  y: -14.49   },
        { name: "RC Willey",        x: 11, y: -0.00    },
        { name: "Aqua Finance",     x: 15, y: -0.00    },
        { name: "Home Depot",       x: 16, y: -200.00  },
        { name: "Lowe’s-Basement",  x: 20, y: -0.00    },
        { name: "Lowe’s",           x: 23, y: -39.00   },
        { name: "Amazon CC",        x: 24, y: -150.00  },

        { name: "Voldemort",        x: 1,  y: -1000.00 },
        { name: "Bike",             x: 16, y: -101.12  },
        { name: "Hyundai",          x: 17, y: -385.84  },
        { name: "Fiesta",           x: 20, y: -0.00    },
        { name: "Trailer",          x: 24, y: -107.59  },
        { name: "Truck",            x: 25, y: -239.98  },

        { name: "House",            x: 7,  y: -2344.96 }
      ]

      PaymentCalendar = svgObj.init(dataset)
      // PaymentCalendar.addDataset(dataset)
    }

    //
    //   svgObj.remove_points = function(points) {
    //     points.forEach(function(point) {
    //       $("[map_id=" + point.id + "]").remove()
    //     })
    //   }
    //
    //   svgObj.add_points = function(points) {
    //     var point = svgObj.map.append("g")
    //       .selectAll("dot")
    //       .data(points)
    //       .enter()
    //     point.append("circle")
    //       .attr("r", 5)
    //       .attr("cx", function(d) { return svgObj.x(d.x) })
    //       .attr("cy", function(d) { return svgObj.y(d.y) })
    //       .attr("map_id", function(d) { return d.id })
    //       .attr("map_x", function(d) { return d.x })
    //       .attr("map_y", function(d) { return d.y })
    //       .attr("pc-color", function(d) { return d.type })
    //       .on("mouseover", function(d) {
    //          svgObj.tooltip.transition()
    //            .duration(200)
    //            .style("opacity", 0.9)
    //          svgObj.tooltip.html(svgObj.pointTooltipHTML(d))
    //            .style("left", (d3.event.pageX) + "px")
    //            .style("top", (d3.event.pageY - 28) + "px")
    //        })
    //        .on("mouseout", function(d) {
    //          svgObj.tooltip.transition()
    //            .duration(500)
    //            .style("opacity", 0)
    //        })
    //        .on("click", svgObj.selectPoint)
    //
    //     // TODO: Connect waypoint to nearby waypoints
    //   }
    //
    //   svgObj.drawCircle = function(center, rad, color) {
    //     svgObj.map.insert("circle", ":first-child")
    //       .attr("class", "distance-circle")
    //       .attr("r", function() { return svgObj.r(rad) })
    //       .attr("cx", function() { return svgObj.x(center.x) })
    //       .attr("cy", function() { return svgObj.y(center.y) })
    //       .attr("stroke", color)
    //       .attr("fill", color)
    //       .style("opacity", 0.1)
    //   }
    //
    //   svgObj.selectPoint = function(point) {
    //     var circle = this
    //     $(".edit-form").removeClass("hidden")
    //     $("circle.selected").removeClass("selected")
    //     $(circle).addClass("selected")
    //
    //     $('input[name="id"]').val(point.id)
    //     $('input[name="location[x_coord]"]').val(point.x)
    //     $('input[name="location[y_coord]"]').val(point.y)
    //     $('input[name="location[title]"]').val(point.title)
    //     $('select[name="location[location_type]"]').val(point.type)
    //     $('textarea[name="location[description]"]').val(point.description)
    //
    //     console.log("Origin: ", point.x, point.y)
    //
    //     $("circle.distance-circle").remove()
    //     svgObj.drawCircle({x: point.x, y: point.y}, 1000, "green")
    //     svgObj.drawCircle({x: point.x, y: point.y}, 2000, "yellow")
    //     svgObj.drawCircle({x: point.x, y: point.y}, 3000, "orange")
    //     svgObj.drawCircle({x: point.x, y: point.y}, 4000, "red")
    //   }
    //

    paymentCalendarSetup()
  }
})
