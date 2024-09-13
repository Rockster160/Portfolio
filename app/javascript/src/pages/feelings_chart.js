$(document).ready(function() {
  if ($(".ctr-action_events.act-feelings").length == 0) { return }

  let dataPoints = JSON.parse($("[data-feelings-data]").attr("data-feelings-data"))
  let ctx = document.createElement("canvas")
  $(".feelings-charts").append(ctx)

  // Normalize labels to ensure variations are grouped together
    function normalizeLabel(label) {
      const labelMap = {
        // "Sad | Happy": "Happy | Sad",
        // "Sleepy | Alert": "Alert | Sleepy",
        // Add any additional mappings here
      };
      return labelMap[label] || label;
    }

    // Extract unique labels from all data points and normalize them
    const datasetLabels = [
      ...new Set(
        dataPoints.flatMap(dp => Object.keys(dp.data).map(normalizeLabel))
      )
    ];

    // Prepare datasets for each normalized attribute
    const datasets = datasetLabels.map(label => ({
      label,
      data: dataPoints.map(dp => ({
        x: dp.timestamp*1000, // Timestamp for correct relative placement
        y: dp.data[Object.keys(dp.data).find(key => normalizeLabel(key) === label)] || null
      })),
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
        datasets
      },
      options: {
        responsive: true,
        scales: {
          x: {
            type: "time",
            time: {
              unit: "day", // Only show day labels
              tooltipFormat: "PPpp", // Full date on hover
              displayFormats: {
                day: "MMM d" // Format for the X-axis labels (e.g., "Sep 13")
              }
            },
            title: {
              display: true,
              text: "Date"
            }
          },
          y: {
            min: 0,
            max: 100,
            beginAtZero: true,
            title: {
              display: true,
              text: "Value"
            }
          }
        }
      }
    });
})
