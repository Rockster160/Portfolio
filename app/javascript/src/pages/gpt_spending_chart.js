import { registerBrokenAxis } from "../support/broken_axis.js"

// The spend-per-bucket chart on /system/gpt_spending: cost as stacked bars per
// person, API calls as a line on its own axis.
$(document).ready(function() {
  if ($(".ctr-system.act-gpt_spending").length == 0) { return }
  if (typeof Chart === "undefined") { return }

  const dataEl = document.getElementById("spend-data")
  const canvas = document.getElementById("spend-chart")
  if (!dataEl || !canvas) { return }

  const payload = JSON.parse(dataEl.textContent)
  registerBrokenAxis()

  const datasets = payload.datasets.map(function(ds) {
    return {
      type: "bar",
      label: ds.label,
      data: ds.data,
      backgroundColor: ds.color,
      borderColor: ds.color,
      borderWidth: 0,
      stack: "spend",
      order: 1,
    }
  })

  datasets.push({
    type: "line",
    label: "API calls",
    data: payload.calls,
    borderColor: "#8B949E",
    backgroundColor: "#8B949E",
    borderWidth: 2,
    pointRadius: 2,
    pointHoverRadius: 4,
    tension: 0.3,
    yAxisID: "calls",
    order: 0,
  })

  new Chart(canvas, {
    type: "bar",
    data: { labels: payload.labels, datasets: datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: "index", intersect: false },
      scales: {
        x: {
          stacked: true,
          ticks: { color: "#C9D1D9", maxRotation: 0, autoSkip: true },
          grid: { color: "rgba(255,255,255,0.05)" },
        },
        y: {
          type: "broken",
          stacked: true,
          beginAtZero: true,
          ticks: {
            color: "#C9D1D9",
            callback: function(value) { return "$" + value.toFixed(2) },
          },
          grid: { color: "rgba(255,255,255,0.05)" },
          title: { display: true, text: "USD", color: "#8B949E" },
        },
        calls: {
          type: "broken",
          // Calls track spend, so its peak lands on the same column as the
          // spend label; the axis beside it already says where it is.
          breakLabels: false,
          position: "right",
          beginAtZero: true,
          ticks: { color: "#8B949E", precision: 0 },
          grid: { drawOnChartArea: false },
          title: { display: true, text: "Calls", color: "#8B949E" },
        },
      },
      plugins: {
        legend: { display: false },
        tooltip: {
          mode: "index",
          intersect: false,
          callbacks: {
            label: function(ctx) {
              if (ctx.dataset.yAxisID === "calls") {
                return ctx.dataset.label + ": " + Number(ctx.parsed.y)
              }
              return ctx.dataset.label + ": $" + Number(ctx.parsed.y).toFixed(4)
            },
          },
        },
      },
    },
  })
})
