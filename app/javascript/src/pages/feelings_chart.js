$(document).ready(function() {
  if ($(".ctr-action_events.act-feelings").length == 0) { return }

  let dataPoints = JSON.parse($("[data-feelings-data]").attr("data-feelings-data"))
  let ctx = document.createElement("canvas")
  $(".feelings-charts").append(ctx)

  // Chart.defaults.backgroundColor = "#0160FF"
  const labels = dataPoints.map(dp => new Date(dp.timestamp * 1000).toLocaleTimeString());

    // Extract datasets from the data
    const datasetLabels = Object.keys(dataPoints[0].data);
    const datasets = datasetLabels.map(label => ({
      label,
      data: dataPoints.map(dp => dp.data[label]),
      fill: false,
      borderColor: getRandomColor(),
      tension: 0.1
    }));

    // Generate random color for each dataset line
    function getRandomColor() {
      return `rgba(${Math.floor(Math.random() * 255)},${Math.floor(Math.random() * 255)},${Math.floor(
        Math.random() * 255
      )},1)`;
    }

    // Create the chart
    const chart = new Chart(ctx, {
      type: "line",
      data: {
        labels, // X-axis (time)
        datasets // Y-axis data for each attribute
      },
      options: {
        responsive: true,
        scales: {
          x: {
            title: {
              display: true,
              text: "Time"
            }
          },
          y: {
            beginAtZero: true,
            title: {
              display: true,
              text: "Value"
            }
          }
        }
      }
    });
  // const config = {
  //   type: "bar",
  //   data: feelings_data,
  //   options: {
  //     scales: {
  //       y: {
  //         max: Math.max(100, ...feelings_data.datasets[0].data),
  //         min: 0,
  //         grid: { color: "#0140AA" },
  //       },
  //     },
  //     plugins: {
  //       legend: { display: false },
  //       horzLine: {
  //         y: 100,
  //         color: "#0140AA",
  //         width: 5,
  //       }
  //     },
  //   },
  //   plugins: [{
  //     id: "horzLine",
  //     beforeDraw(chart, args, options) {
  //       const {ctx, chartArea: {left, top, width, height}} = chart
  //       let yPixel = chart.scales.y.getPixelForValue(options.y)
  //       ctx.save()
  //       ctx.beginPath()
  //       ctx.strokeStyle = options.color
  //       ctx.lineWidth = options.width
  //       ctx.moveTo(left - 5, yPixel)
  //       ctx.lineTo(left + width - 5, yPixel)
  //       ctx.stroke()
  //       ctx.restore()
  //     }
  //   }]
  // }
  //
  // let chart = new Chart(ctx, config)
})
