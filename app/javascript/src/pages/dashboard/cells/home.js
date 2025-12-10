import { Monitor } from "./monitor";
import { Time } from "./_time";
import { Text } from "../_text";
import { ColorGenerator } from "./color_generator";
import { dash_colors, beep, scaleVal, clamp } from "../vars";

(function () {
  var cell = undefined;
  let flashing = undefined;
  let flash_on = true;

  class Order {
    static _render = true;
    static get render() {
      return this._render;
    }
    static set render(val) {
      this._render = val;
      if (val) {
        renderLines();
      }
    }

    static add(name) {
      cell.amz_socket.send({ action: "change", add: name });
    }

    constructor(data) {
      this._data = { ...data };
    }
    // Immutable properties
    get full_id() {
      return `${this._data.order_id}-${this._data.item_id}`;
    }
    get order_id() {
      return this._data.order_id;
    }
    get item_id() {
      return this._data.item_id;
    }

    // Mutable properties
    get name() {
      return this._data.name;
    }
    set name(val) {
      this._update("name", val);
    }

    get errors() {
      return this._data.errors;
    }
    set errors(val) {
      this._update("errors", val);
    }

    get delivered() {
      return this._data.delivered;
    }
    set delivered(val) {
      this._update("delivered", val);
    }

    get date() {
      return this._data.date;
    }
    set date(val) {
      this._update("date", val);
    }

    get time_range() {
      return this._data.time_range;
    }
    set time_range(val) {
      this._update("time_range", val);
    }

    get email_ids() {
      return this._data.email_ids;
    }
    set email_ids(val) {
      this._update("email_ids", val);
    }

    remove() {
      cell.amz_socket.send({
        action: "change",
        order_id: this.order_id,
        item_id: this.item_id,
        remove: true,
      });
    }

    openAmz() {
      let url = "https://www.amazon.com/gp/your-account/order-details?orderID=";
      window.open(url + this.order_id.replace("#", ""), "_blank");
    }

    openEmails() {
      this.email_ids?.forEach((id) =>
        window.open(`https://ardesian.com/emails/${id}`, "_blank"),
      );
    }

    _update(prop, newVal, fromSocket = false) {
      const oldVal = this._data[prop];
      if (oldVal !== newVal) {
        this._data[prop] = newVal;
        if (!fromSocket && prop === "name") {
          cell.amz_socket.send({
            action: "change",
            order_id: this.order_id,
            item_id: this.item_id,
            rename: newVal,
          });
        }
        renderLines();
      }
      return oldVal !== newVal;
    }

    updateFromSocket(newData) {
      if ("name" in newData) this._update("name", newData.name, true);
      if ("errors" in newData) this._update("errors", newData.errors, true);
      if ("delivered" in newData)
        this._update("delivered", newData.delivered, true);
      if ("date" in newData) this._update("date", newData.date, true);
      if ("time_range" in newData)
        this._update("time_range", newData.time_range, true);
      if ("email_ids" in newData)
        this._update("email_ids", newData.email_ids, true);
    }
  }

  let flash = function (active) {
    if (active) {
      flashing = flashing || setInterval(renderLines, 400);
    } else {
      clearInterval(flashing);
      flashing = undefined;
    }
  };

  let battery_color_scale = ColorGenerator.colorScale(
    (function () {
      let colors = {};
      colors[dash_colors.red] = 30;
      colors[dash_colors.yellow] = 50;
      colors[dash_colors.green] = 95;
      return colors;
    })(),
  );

  let batteryIcon = function (name, icon) {
    let data = cell.data.device_battery[name];
    if (!data) {
      return "";
    }
    let val = data.val;
    if (!val) {
      return Text.grey(icon + "?");
    }
    let char = clamp(Math.round(scaleVal(val, 10, 90, 0, 7)), 0, 7);
    let level = "▁▂▃▄▅▆▇█"[char];
    let reported_at = Time.at(data.time);
    let battery_color = battery_color_scale(val).hex;
    if (Time.now() - reported_at > Time.hours(12)) {
      battery_color = dash_colors.grey;
    } else if (val == 100) {
      battery_color = dash_colors.rocco;
    }
    return icon + Text.color(battery_color, level);
  };

  function shortAgo(timestamp) {
    const now = Math.floor(Date.now() / 1000);
    const at = parseInt(timestamp);
    if (isNaN(at)) {
      return timestamp;
    }
    const elapsed = now - at;

    const secondsInMinute = 60;
    const secondsInHour = 3600;

    if (elapsed < secondsInMinute) {
      return `${elapsed}s`;
    } else if (elapsed < secondsInHour) {
      const minutes = Math.floor(elapsed / secondsInMinute);
      return `${minutes}m`;
    } else {
      const hours = Math.floor(elapsed / secondsInHour);
      return hours > 99 ? Text.grey("--h") : `${hours}h`;
    }
  }

  let renderLines = function () {
    let lines = [];
    let first_row = [];
    first_row.push(cell.data.loading ? "[ico ti ti-fa-spinner ti-spin]" : "");
    if (cell.data?.garage?.timestamp < Time.ago(Time.hour)) {
      cell.data.garage.state = "unknown";
    }

    if ("state" in (cell.data?.garage || {})) {
      if (cell.data.garage.state == "open") {
        flash(false);
        first_row.push(Text.orange("[ico ti ti-mdi-garage_open]"));
      } else if (cell.data.garage.state == "closed") {
        flash(false);
        first_row.push(Text.green("[ico ti ti-mdi-garage]"));
      } else if (cell.data.garage.state == "between") {
        flash(true);
        if ((flash_on = !flash_on)) {
          first_row.push(Text.yellow("[ico ti ti-mdi-garage_open]"));
          if (cell.data.sound) {
            beep(100, 350, 0.02, "square");
          }
        } else {
          first_row.push(Text.yellow("  "));
        }
      } else {
        flash(false);
        first_row.push(Text.grey(" [ico ti ti-mdi-garage]?"));
      }
      first_row.push(shortAgo(cell.data.garage.timestamp / 1000));
    } else {
      flash(false);
      first_row.push(Text.grey(" [ico ti ti-mdi-garage]?"));
    }

    if (cell.data.camera) {
      ["Doorbell", "Driveway", "Backyard", "Storage"].forEach((location) => {
        const data = cell.data.camera[location] || { at: "?", type: "?" };
        let typeIcon = Text.grey;
        const locIcon = {
          Doorbell: "[ico ti ti-mdi-door]",
          Driveway: "[ico ti ti-fa-car]",
          Backyard: "[ico ti ti-fae-plant]",
          Storage: "[ico ti ti-fa-dropbox]",
        }[location];
        switch (data.type) {
          case "person":
            typeIcon = Text.lblue;
            break;
          case "pet":
            typeIcon = Text.purple;
            break;
          case "vehicle":
            typeIcon = Text.yellow;
            break;
          case "motion":
            typeIcon = Text.grey;
            break;
        }
        const time = shortAgo(data.at) || "--";

        if (locIcon) {
          first_row.push(typeIcon(` ${locIcon}${time}`));
        }
      });
    }

    lines.push(Text.center(first_row.join("")));

    cell.data.devices?.forEach(function (device) {
      let mode_color = dash_colors.grey;
      switch (device.current_mode) {
        case "cool":
          mode_color = dash_colors.lblue;
          break;
        case "heat":
          mode_color = dash_colors.orange;
          break;
        case "off":
          mode_color = dash_colors.grey;
          break;
      }
      let name = device.name + ":";
      let current = device.current_temp + "°";
      let goal = Text.color(
        mode_color,
        "[" + (device.cool_set || device.heat_set || "off") + "°]",
      );
      let on = null;
      if (device.status == "cooling") {
        on = Emoji.snowflake + Emoji.dash;
      }
      if (device.status == "heating") {
        on = Emoji.fire + Emoji.dash;
      }

      lines.push(Text.center([name, current, goal, on].join(" ")));
    });

    let battery_icons = {
      Phone: "[ico ti ti-fa-mobile_phone]",
      Watch: "[ico ti ti-oct-watch]",
      iPad: "[ico ti ti-mdi-tablet_ipad]",
      Pencil: "[ico ti ti-mdi-pencil]",
      TrackPad: "[ico ti ti-mdi-mouse]",
    };
    let battery_line = [];
    for (let [name, icon] of Object.entries(battery_icons)) {
      // Check last updated
      battery_line.push(batteryIcon(name, icon));
    }
    lines.push(Text.center(battery_line.join(" ")));

    cell.data.orders.forEach(function (order, idx) {
      let delivery = Text.grey("?");
      let name = order.name || Text.grey("?");

      if (order.errors?.length > 0) {
        name = Text.red(name);
      }

      if (order.delivered) {
        // Detect if previously NOT delivered, and if so- beep
        delivery = Text.green("✓");
      } else if (order.date) {
        delivery = Text.magenta(
          order.date.toLocaleString("en-us", {
            weekday: "short",
            month: "short",
            day: "numeric",
          }),
        );

        let delivery_date = order.date.getTime();
        if (Time.beginningOfDay() > delivery_date) {
          delivery = Text.orange("Delayed?");
        } else if (Time.beginningOfDay() + Time.day() > delivery_date) {
          delivery = Text.green(order.time_range ? order.time_range : "Today");
        } else if (Time.beginningOfDay() + Time.days(2) > delivery_date) {
          delivery = Text.yellow("Tmrw");
        } else if (Time.beginningOfDay() + Time.days(6) > delivery_date) {
          delivery = Text.blue(
            order.date.toLocaleString("en-us", { weekday: "short" }),
          );
        }
      }

      lines.push(Text.justify(idx + 1 + ". " + name, delivery));
    });

    cell.lines(lines);
  };
  setInterval(renderLines, Time.second());

  let getGarage = function () {
    cell.recent_garage = false;
    cell.garage_monitor?.resync();

    // If no response within 10 seconds, forget the current state
    clearTimeout(cell.garage_timeout);
    cell.garage_timeout = setTimeout(function () {
      cell.garage_monitor?.resync();
      console.log("Timed out waiting for garage response");
      cell.data.garage.state = "unknown";
      renderLines();
    }, Time.seconds(10));
  };

  let subscribeWebsockets = function () {
    cell.amz_socket = new CellWS(
      cell,
      Server.socket("AmzUpdatesChannel", function (msg) {
        Order.render = false;
        this.flash();

        const currentOrders = cell.data.orders || [];
        const updatedOrders = [];
        msg.forEach((order_data) => {
          if (order_data.delivery_date) {
            let [year, month, day, ...tz] =
              order_data.delivery_date.split(/-| /);
            let date = new Date(0);
            date.setFullYear(year, parseInt(month) - 1, day);
            if (order_data.time_range) {
              let meridian = order_data.time_range.match(/([^\d]*?)$/)[1];
              let hour = parseInt(
                order_data.time_range.match(/(\d+)[^\d]*?$/)[1],
              );
              if (meridian == "pm") {
                hour += 12;
              }
              date.setHours(hour);
            }
            order_data.date = date;
          }

          let existing = currentOrders.find(
            (o) => o.full_id === `${order_data.order_id}-${order_data.item_id}`,
          );
          if (existing) {
            existing.updateFromSocket(order_data);
            updatedOrders.push(existing);
          } else {
            updatedOrders.push(new Order(order_data));
          }
        });
        this.data.orders = updatedOrders.sort((a, b) => {
          // delivered status takes priority
          if (b.delivered - a.delivered !== 0) {
            return b.delivered - a.delivered;
          }
          return a.date - b.date;
        });
        Order.render = true;
      }),
    );
    cell.amz_socket.send({ action: "request" });

    cell.device_battery_socket = new CellWS(
      cell,
      Server.socket("DeviceBatteryChannel", function (msg) {
        this.flash();

        if (msg.Phone) {
          cell.data.device_battery.Phone = msg.Phone;
        }
        if (msg.iPad) {
          cell.data.device_battery.iPad = msg.iPad;
        }
        if (msg.Watch) {
          cell.data.device_battery.Watch = msg.Watch;
        }
        if (msg.Pencil) {
          cell.data.device_battery.Pencil = msg.Pencil;
        }
        if (msg.TrackPad) {
          cell.data.device_battery.TrackPad = msg.TrackPad;
        }

        renderLines();
      }),
    );
    cell.device_battery_socket.send({ action: "request" });

    cell.garage_monitor = Monitor.subscribe("garage", {
      connected: function () {
        console.log("socket Connected");
        setTimeout(function () {
          cell.garage_monitor?.resync();
        }, 1000);
        // can also set the arrow?
        // this.send({ request: "open" })
        // this.send({ request: "close" })
        // this.send({ request: "toggle" })
      },
      disconnected: function () {
        console.log("socket Disconnected");
        cell.data.garage.state = "unknown";
        renderLines();
      },
      received: function (data) {
        clearTimeout(cell.garage_timeout);
        cell.flash();
        if (data.loading) {
        } else {
          cell.data.camera = data.data?.camera || {};
          cell.data.garage.timestamp = data.timestamp * 1000;
          let msg = data.result || "";
          if (
            msg.includes("[ico mdi-garage font-size: 100px; color: green;]")
          ) {
            cell.data.garage.state = "closed";
          } else if (msg.includes("yellow; animation: 1s infinite blink")) {
            cell.data.garage.state = "between";
          } else if (
            msg.includes(
              "[ico mdi-garage_open font-size: 100px; color: orange;]",
            )
          ) {
            cell.data.garage.state = "open";
          } else {
            cell.data.garage.state = "unknown";
          }
          renderLines();
        }
      },
    });

    cell.nest_socket = new CellWS(
      cell,
      Server.socket("NestChannel", function (msg) {
        this.flash();

        if (msg.failed) {
          this.data.loading = false;
          this.data.failed = true;
          clearInterval(this.data.nest_timer); // Don't try anymore until we manually update
          renderLines();
          return;
        } else {
          this.data.failed = false;
        }
        if (msg.loading) {
          this.data.loading = true;
          renderLines();
          return;
        }

        this.data.loading = false;
        this.data.devices = msg.devices;

        renderLines();
      }),
    );
    setTimeout(() => {
      cell.nest_socket.send({ action: "command", settings: "update" });
      this.data.nest_timer = setInterval(function () {
        cell.nest_socket.send({ action: "command", settings: "update" });
      }, Time.minutes(10));
    }, Time.seconds(30)); // Wait 30 seconds before attempting to connect
  };

  cell = Cell.register({
    title: "Home",
    refreshInterval: Time.hour(),
    wrap: false,
    flash: false,
    data: {
      sound: true,
      device_battery: {},
      orders: [],
      garage: { state: "unknown", timestamp: 0 },
      camera: { Backyard: {}, Driveway: {}, Doorbell: {}, Storage: {} },
    },
    onload: subscribeWebsockets,
    reloader: function () {
      getGarage();
      renderLines();
      // Update times? "1 minute ago", etc...
    },
    started: function () {
      cell.amz_socket.reopen();
      cell.device_battery_socket.reopen();
      cell.nest_socket.reopen();
    },
    stopped: function () {
      cell.amz_socket.close();
      cell.device_battery_socket.close();
      cell.nest_socket.close();
    },
    commands: {
      quiet: function () {
        cell.data.sound = !cell.data.sound;
      },
      open: function (idx) {
        if (idx) {
          let order = cell.data.orders[parseInt(idx) - 1];
          order?.email_ids?.forEach((id) =>
            window.open(`https://ardesian.com/emails/${id}`, "_blank"),
          );
        }
      },
    },
    command: function (msg) {
      if (msg.trim() == "o") {
        window.open(cell.config.google_api_url, "_blank");
      } else if (/^-?\d+/.test(msg) && parseInt(msg.match(/\d+/)[0]) < 30) {
        var num = parseInt(msg.match(/\d+/)[0]);
        let order = this.data.orders[num - 1];
        if (!order) {
          return;
        }

        if (/^-\d+/.test(msg)) {
          // Use - to remove item
          order.remove();
        } else if (/^\d+\s*$/.test(msg)) {
          // No words means open the order
          order.openAmz();
        } else if (/^\d+\s*o\b$/.test(msg)) {
          // "o" means open the email
          order.openEmails();
        } else {
          // Rename the order
          order.name = msg.replace(/^\d+\s*/, "");
        }
      } else if (/^add\b/i.test(msg)) {
        // Add item to AMZ deliveries
        Order.add(msg.replace(/^add\s*/i, ""));
      } else if (/\b(open|close|toggle|garage)\b/.test(msg)) {
        // open/close
        cell.garage_monitor.send({
          channel: "garage",
          request: msg.match(/\b(open|close|toggle)\b/)[0],
        });
      } else {
        // Assume AC control
        cell.nest_socket.send({ action: "command", settings: msg });
      }
    },
  });
})();
