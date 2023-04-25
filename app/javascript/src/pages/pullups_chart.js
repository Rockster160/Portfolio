$(document).ready(function() {
  if ($(".ctr-action_events.act-pullups").length == 0) { return }

  let pullups_data = JSON.parse($("[data-pullups-data]").attr("data-pullups-data"))
  let ctx = document.createElement("canvas")
  $(".pullups-charts").append(ctx)

  // Chart.defaults.backgroundColor = "#0160FF"
  const config = {
    type: "bar",
    data: pullups_data,
    options: {
      scales: {
        y: {
          grid: {
            color: "#0140AA"
          }
        }
      },
      plugins: { legend: { display: false } },
    }
  }

  let chart = new Chart(ctx, config)
})
