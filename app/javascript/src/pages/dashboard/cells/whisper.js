import { Time } from "./_time";
import { Text } from "../_text";
import { Monitor } from "./monitor";
import { dash_colors } from "../vars";

(function () {
  var cell = undefined;
  const cell_width = 32;
  const half_width = 16;
  const birthDateMs = 1760432400000; // October 14, 2025 at 3am Denver (MDT = UTC-6)

  const buttonMonitors = [
    "whisper-btn-1",
    "whisper-btn-2",
    "whisper-btn-fed",
    "whisper-btn-nap-toggle",
    // "whisper-btn-home-toggle",
    // "whisper-btn-sleep",
  ];

  function calculateAge() {
    const birth = new Date(birthDateMs);
    const now = Time.now();

    let totalMonths =
      (now.getFullYear() - birth.getFullYear()) * 12 +
      (now.getMonth() - birth.getMonth());

    if (now.getDate() < birth.getDate()) {
      totalMonths--;
    }

    const years = Math.floor(totalMonths / 12);
    const months = totalMonths % 12;
    const weeks = Math.floor((now - birth) / (7 * 24 * 60 * 60 * 1000));

    let ageStr;
    if (years === 0) {
      ageStr = `${months}m`;
    } else if (months === 0) {
      ageStr = `${years}y`;
    } else {
      ageStr = `${years}y ${months}m`;
    }

    return `${ageStr} (${weeks}w)`;
  }

  function formatRemaining(seconds) {
    const abs = Math.abs(seconds);
    const m = Math.floor(abs / 60);
    const sign = seconds < 0 && m != 0 ? "-" : "";
    return `${sign}${m}m`;
  }

  function renderTimerBar(timerData) {
    if (!timerData) return " ".repeat(half_width);

    const nowSec = Math.floor(Time.msSinceEpoch() / 1000);
    const last = timerData.last || nowSec;
    const next = timerData.next || nowSec;

    const totalDuration = next - last;
    const remaining = next - nowSec;

    // Progress goes from 1 (full) to 0 (empty) as time elapses
    const progress =
      totalDuration > 0 ? Math.max(remaining / totalDuration, 0) : 0;
    const isOverdue = remaining <= 0;

    const label = timerData.label || timerData.key || "";
    const timeStr = formatRemaining(remaining);

    const barWidth = half_width - 2;
    const textContent = Text.justify(
      barWidth,
      " " + Text.trunc(label.toUpperCase(), barWidth - timeStr.length - 2),
      timeStr + " ",
    );

    const fillCells = Math.round(barWidth * progress);
    const filled = Text.bgColor(
      dash_colors.green,
      textContent.slice(0, fillCells),
    );
    const empty = Text.bgColor(
      isOverdue ? dash_colors.red : dash_colors.darkgrey,
      textContent.slice(fillCells),
    );

    return " " + filled + empty;
  }

  function renderButtonLine(idx, btnData, timerData) {
    const num = idx + 1;
    let leftSide = "";

    if (btnData && btnData.text) {
      const numStr = Text.color(dash_colors.grey, `${num}.`);
      const mainText = `${numStr} ${btnData.text}`;
      const subtext = btnData.subtext
        ? Text.color(
            dash_colors.grey,
            `(${btnData.subtext.replace(/^Last: /, "").replace(/m$/, "")})`,
          )
        : "";

      leftSide = Text.justify(half_width, mainText, subtext);
    } else {
      leftSide = " ".repeat(half_width);
    }

    const rightSide = renderTimerBar(timerData);

    return leftSide + rightSide;
  }

  function renderListLine(idx, listItem) {
    const num = idx + 6;
    const numStr = Text.color(dash_colors.grey, `${num}.`);
    if (!listItem) return `${numStr} `;

    return `${numStr} ${listItem.name || listItem}`;
  }

  function render() {
    const lines = [];

    // Line 1: Status | Emoji + Age
    const status = cell.data.status || "";
    const ageStr = calculateAge();
    lines.push(
      Text.justify(
        cell_width,
        "🐶".padEnd(ageStr.length),
        status,
        Text.color(dash_colors.grey, ageStr),
      ),
    );

    // Line 2: Blank
    lines.push("");

    // Lines 3-7 (idx 0-4): Button monitors + timers
    for (let i = 0; i < 5; i++) {
      const btnData = cell.data.buttons[i] || {};
      const timerData = cell.data.timers[i] || null;
      lines.push(renderButtonLine(i, btnData, timerData));
    }

    // Lines 8-9 (idx 5-6): List items
    const listItems = cell.data.listItems || [];
    lines.push(renderListLine(0, listItems[0]));
    lines.push(renderListLine(1, listItems[1]));

    cell.lines(lines);
  }

  function subscribeToButtonMonitors() {
    cell.data.monitorRefs = [];
    buttonMonitors.forEach((monitorName, idx) => {
      const monitor = Monitor.subscribe(monitorName, {
        connected: function () {
          this.refresh();
        },
        received: function (data) {
          const monitorData = data?.data;
          if (!monitorData) return;

          cell.data.buttons[idx] = monitorData;
          cell.flash();
          render();
        },
      });
      cell.data.monitorRefs[idx] = monitor;
    });
  }

  function subscribeToDurations() {
    Monitor.subscribe("whisper-durations", {
      connected: function () {
        this.refresh();
      },
      received: function (data) {
        const monitorData = data?.data;
        if (!monitorData) return;

        if (monitorData.status !== undefined) {
          cell.data.status = monitorData.status;
        }

        if (Array.isArray(monitorData.timers)) {
          cell.data.timers = monitorData.timers;
        }

        cell.flash();
        render();
      },
    });
  }

  function subscribeToList() {
    cell.listSocket = new CellWS(
      cell,
      Server.socket(
        {
          channel: "ListJsonChannel",
          channel_id: "list_360",
        },
        function (msg) {
          if (!msg.list_data) return;

          cell.data.listItems = msg.list_data.items || [];
          cell.flash();
          render();
        },
      ),
    );

    cell.listSocket.send({ get: true });
  }

  function setupJarvisSocket() {
    cell.jarvisSocket = new CellWS(
      cell,
      Server.socket("JarvisChannel", function () {}),
    );
  }

  function sendJarvisCommand(text) {
    if (cell.jarvisSocket) {
      cell.jarvisSocket.send({ action: "command", words: text });
    }
  }

  cell = Cell.register({
    title: "Whisper",

    refreshInterval: Time.second(),
    flash: false,
    wrap: false,
    data: {
      status: "",
      buttons: [{}, {}, {}, {}, {}],
      timers: [],
      listItems: [],
    },
    onload: function () {
      subscribeToButtonMonitors();
      subscribeToDurations();
      subscribeToList();
      setupJarvisSocket();
    },
    reloader: function () {
      render();
    },
    command: function (text) {
      text = text.trim();

      // Number command (1-5): execute button action
      if (/^[1-5]$/.test(text)) {
        const num = parseInt(text);
        const monitor = cell.data.monitorRefs[num - 1];
        if (monitor) {
          monitor.execute();
        }
        return;
      }

      // Remove list item: -6 or -7
      if (/^-[67]$/.test(text)) {
        const num = parseInt(text.match(/\d+/)[0]);
        const listIdx = num - 6;
        const item = cell.data.listItems[listIdx];
        if (item && cell.listSocket) {
          cell.listSocket.send({ remove: item.name || item });
        }
        return;
      }

      // Log command: "Log ..."
      if (/^log\s+/i.test(text)) {
        const logText = text.replace(/^log\s+/i, "").trim();
        if (logText) {
          sendJarvisCommand(`Log Whisper ${logText}`);
        }
        return;
      }

      const itemText = text.replace(/^add\s+/i, "").trim();
      if (itemText && cell.listSocket) {
        cell.listSocket.send({ add: itemText });
      }
      return;
    },
  });
})();
