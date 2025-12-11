// localStorage.setItem("jarvis_history", localStorage.getItem("jarvis_history")?.split("\n")?.slice(6, 50).join("\n"))
import { Time } from "./_time";
import { toggleMute } from "../vars";

(function () {
  let cell = undefined;

  let renderLines = function (history) {
    cell.lines((history || getHistory()).slice(cell.data.scroll || 0, 50));
  };

  let getHistory = function () {
    return (
      localStorage.getItem("jarvis_history")?.split("\n")?.slice(0, 50) || []
    );
  };

  let saveHistory = function (lines) {
    return localStorage.setItem("jarvis_history", lines.join("\n") || []);
  };

  let addHistory = function (line) {
    let history = getHistory();
    history.unshift("[" + Time.local() + "] " + line);
    saveHistory(history);
    renderLines(history);
  };

  cell = Cell.register({
    title: "Jarvis",
    wrap: true,
    onload: function () {
      this.data.scroll = 0;
      renderLines();
    },
    socket: Server.socket("JarvisChannel", function (msg) {
      if (msg.data) {
        console.log(msg.data);
      }

      if (msg.data?.reload || msg.data === "reload") {
        window.location.reload();
        return;
      }

      if (msg.say?.trim()?.length > 0) {
        let history = getHistory();
        if (/^Logged \w( |\*|ish|$)/.test(msg.say)) {
          return renderLines(history); // Remove loading spinner
        }
        if (!/^Logged /.test(msg.say) || /\[/.test(msg.say)) {
          addHistory(msg.say);
        }

        renderLines(history); // Remove loading spinner
      }

      this.flash();
    }),
    command: function (text) {
      if (/^-\d+$/.test(text)) {
        const num = parseInt(text.match(/\d+/)[0]);
        if (num === 0) {
          return renderLines();
        } // -0 removes loading indicator
        let newHistory = getHistory();
        newHistory.splice(num - 1, 1);
        saveHistory(newHistory);
        renderLines();
      } else {
        cell.lines(["[ico ti ti-fa-spinner ti-spin]", ...getHistory()]);
        cell.ws.send({ action: "command", words: text });
      }
    },
    commands: {
      clear: function () {
        localStorage.setItem("jarvis_history", "");
        this.text("");
      },
      mute: function () {
        if (toggleMute()) {
          addHistory("Dashboard muted.");
        } else {
          addHistory("Dashboard unmuted.");
        }
      },
    },
    onfocus: function () {
      this.data.scroll = 0;
      renderLines();
    },
    onblur: function () {
      this.data.scroll = 0;
      renderLines();
    },
    livekey: function (evt_key) {
      this.data.scroll = this.data.scroll || 0;

      evt_key = evt_key.toLowerCase();
      if (evt_key == "arrowup" || evt_key == "w") {
        if (this.data.scroll > 0) {
          this.data.scroll -= 1;
        }
      } else if (evt_key == "arrowdown" || evt_key == "s") {
        if (this.data.scroll < getHistory().length) {
          this.data.scroll += 1;
        }
      }

      renderLines();
    },
  });
})();
