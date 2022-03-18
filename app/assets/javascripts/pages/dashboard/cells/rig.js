$(".ctr-dashboard").ready(function() {
  if (demo) { return }
  Cell.init({
    x: 3,
    y: 2,
    title: "Rig",
    text: "Loading...",
    data: {
      base_url: "https://api2.hiveos.farm/api/v2",
      api_token: authdata.hiveos,
    },
    interval: Time.minutes(10),
    reloader: function(cell) {
      fetch(cell.data.base_url + "/farms", {
        method: "GET",
        headers: { "Authorization": "Bearer " + cell.data.api_token }
      }).then(function(res) {
        res.json().then(function(json) {
          if (res.ok) {
            var lines = []
            lines.push("")
            json.data.forEach(function(rig) {
              if (rig.name == "Brendan Sr Murton") { return }
              lines.push(" " + rig.name)
              var online = "█ ".repeat(rig.stats.gpus_online)
              var offline = "█ ".repeat(rig.stats.gpus_total - rig.stats.gpus_online)
              lines.push(Text.center(Text.color("green", online) + Text.color("red", offline)))
              lines.push("")
            })
            cell.lines(lines)
          } else {
            console.log("Error fetching farms: ", JSON.stringify(json));
          }
        })
      })
    },
  })
})
// data = {
//   "id": 1583802,
//   "name": "Ardesian Farm",
//   "timezone": "US/Mountain",
//   "nonfree": false,
//   "twofa_required": false,
//   "trusted": true,
//   "gpu_red_temp": 72,
//   "asic_red_temp": 85,
//   "gpu_red_fan": 100,
//   "asic_red_fan": 100,
//   "gpu_red_asr": 95,
//   "asic_red_asr": 95,
//   "gpu_red_la": 1,
//   "asic_red_la": 3,
//   "gpu_red_cpu_temp": 70,
//   "gpu_red_mem_temp": 90,
//   "asic_red_board_temp": 85,
//   "autocreate_hash": "164fac5a3670d98b13b39f815126ddd1e2442a17",
//   "locked": false,
//   "power_price": 0.14,
//   "power_price_currency": "usd",
//   "tag_ids": [],
//   "auto_tags": true,
//   "workers_count": 2,
//   "rigs_count": 2,
//   "asics_count": 0,
//   "disabled_rigs_count": 0,
//   "disabled_asics_count": 0,
//   "owner": {
//     "id": 1061675,
//     "login": "quadulur",
//     "name": "quadulur",
//     "me": true
//   },
//   "money": {
//     "is_paid": true,
//     "is_free": false,
//     "paid_cause": "auto",
//     "balance": 0,
//     "discount": 0,
//     "daily_cost": 0.05998,
//     "monthly_cost": 1.85923,
//     "days_left": 0,
//     "overdraft": false,
//     "cost_details": [
//       {
//         "type": 13,
//         "type_name": "Rig on non-brand pool",
//         "amount": 1.02083,
//         "monthly_price": 3,
//         "monthly_cost": 3.0625,
//         "daily_cost": 0.09879
//       }
//     ],
//     "daily_price": 0.05998,
//     "monthly_price": 1.85923,
//     "daily_use_rigs": 1.02083,
//     "daily_use_asics": 0,
//     "price_per_rig": 3,
//     "price_per_asic": 2
//   },
//   "stats": {
//     "workers_total": 2,
//     "workers_online": 2,
//     "workers_offline": 0,
//     "workers_overheated": 0,
//     "workers_no_temp": 0,
//     "workers_overloaded": 0,
//     "workers_invalid": 0,
//     "workers_low_asr": 0,
//     "workers_no_hashrate": 0,
//     "rigs_total": 2,
//     "rigs_online": 2,
//     "rigs_offline": 0,
//     "rigs_power": 1565,
//     "gpus_total": 8,
//     "gpus_online": 8,
//     "gpus_offline": 0,
//     "gpus_overheated": 0,
//     "gpus_no_temp": 0,
//     "asics_total": 0,
//     "asics_online": 0,
//     "asics_offline": 0,
//     "asics_power": 0,
//     "boards_total": 0,
//     "boards_online": 0,
//     "boards_offline": 0,
//     "boards_overheated": 0,
//     "boards_no_temp": 0,
//     "cpus_online": 0,
//     "devices_total": 0,
//     "devices_online": 0,
//     "devices_offline": 0,
//     "power_draw": 1565,
//     "power_cost": 0.22,
//     "asr": 100
//   },
//   "hashrates": [
//     {
//       "algo": "ethash",
//       "hashrate": 480730
//     }
//   ],
//   "hashrates_by_coin": [
//     {
//       "coin": "ETH",
//       "algo": "ethash",
//       "hashrate": 480730
//     }
//   ],
//   "hardware_power_draw": 100,
//   "charge_on_pool": false
// }
