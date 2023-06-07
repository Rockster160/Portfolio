$(document).ready(function() {
  if ($(".ctr-action_events.act-pullups").length == 0) { return }

  let pullups_data = JSON.parse($("[data-pullups-data]").attr("data-pullups-data"))
  let ctx = document.createElement("canvas")
  $(".pullups-charts").append(ctx)

  Chart.defaults.backgroundColor = "#0160FF"
  const config = {
    type: "bar",
    data: pullups_data,
    options: {
      scales: {
        y: {
          max: Math.max(100, ...pullups_data.datasets[0].data),
          min: 0,
          grid: { color: "#0140AA" },
        },
      },
      plugins: {
        legend: { display: false },
        horzLine: {
          y: 100,
          color: "#0140AA",
          width: 5,
        }
      },
    },
    plugins: [{
      id: "horzLine",
      beforeDraw(chart, args, options) {
        const {ctx, chartArea: {left, top, width, height}} = chart
        let yPixel = chart.scales.y.getPixelForValue(options.y)
        ctx.save()
        ctx.beginPath()
        ctx.strokeStyle = options.color
        ctx.lineWidth = options.width
        ctx.moveTo(left - 5, yPixel)
        ctx.lineTo(left + width - 5, yPixel)
        ctx.stroke()
        ctx.restore()
      }
    }]
  }

  let chart = new Chart(ctx, config)
})
