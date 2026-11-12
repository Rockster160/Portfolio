import { Text } from "../_text";
import { beep, dash_colors } from "../vars";
import { snapshotGate } from "../../../lists/snapshot_order";
import { PendingRemovals } from "./pending_removals";

export class ListCell {
  constructor(list_name) {
    let cell = undefined;
    let listData = null;

    const pending = new PendingRemovals({
      send: (packet) => cell.socket?.send(packet),
      isOpen: () => !!cell.socket?.open,
    });

    // Item names in the order they're drawn, so a line number maps back to the
    // item without parsing the markup on that line.
    const renderedNames = () => (listData ? listData.items.map((item) => item.name) : []);

    const plainText = () => {
      return renderedNames().map((name, idx) => `${idx + 1}. ${name}`).join("\n");
    };

    const render = () => {
      if (!listData) {
        return;
      }

      const section_colors = {};
      listData.sections.forEach((section) => {
        section_colors[section.id] = section.color;
      });

      const lines = listData.items.map((item, idx) => {
        let item_idx = `${idx + 1}.`;
        if (item.section_id && section_colors[item.section_id]) {
          item_idx = Text.bgColor(section_colors[item.section_id], item_idx);
        }

        let name = item.name;
        if (pending.has(item.name)) {
          name = Text.color(dash_colors.red, Text.strike(name));
        }

        return `${item_idx} ${name}`;
      });

      cell.text(lines.join("\n"));
    };

    const togglePending = (name) => {
      if (!name) {
        return;
      }
      pending.toggle(name);
      render();
    };

    let setList = async function (name) {
      cell.title(name);
      cell.text("Loading...");
      cell.socket?.close();
      listData = null;

      const url = `${window.location.origin}/lists/${name}`;
      cell.list = await fetch(url)
        .then((res) => res.json())
        .then((json) => {
          return json;
        });

      cell.title(cell.list.name);
      const fresh = snapshotGate();
      const socket = Server.socket(
        {
          channel: "ListJsonChannel",
          channel_id: "list_" + cell.list.id,
        },
        function (msg) {
          if (!msg.list_data) {
            return;
          }
          if (!fresh(msg.timestamp)) {
            return;
          }

          const before = listData ? plainText() : null;
          listData = msg.list_data;
          const after = plainText();
          if (before != null) {
            if (before.length < after.length) {
              beep(50, 1300, 0.1, "sine"); // Added
            } else if (before.length > after.length) {
              beep(60, 800, 0.1, "sine"); // Removed
            }
          }

          pending.update(renderedNames());
          render();
          cell.flash();
        },
      );
      socket.onopen = function () {
        pending.flush();
      };
      cell.socket = new CellWS(cell, socket);

      cell.socket.send({ get: true });
    };

    cell = Cell.register({
      title: list_name,
      text: "Loading...",
      wrap: true,
      onload: function () {
        setList(list_name);
        setInterval(() => pending.retry(), 1000);
      },
      reloader: function () {
        cell.socket?.send({ get: true });
      },
      commands: {
        set: function (msg) {
          setList(msg);
        },
      },
      oncontextmenu: function (evt, ctx) {
        if (ctx.lineIndex == null || ctx.charIndex == null) return;
        const rawLine = this.lines()[ctx.lineIndex];
        if (!rawLine) return;

        const cleanLine = rawLine.replace(/\[bg [^\]]*\]|\[\/bg\]/g, "");
        const numMatch = cleanLine.match(/^\d+\.\s/);
        if (!numMatch) return;

        if (ctx.charIndex >= numMatch[0].length) return;

        evt.preventDefault();
        togglePending(renderedNames()[ctx.lineIndex]);
      },
      command: function (text) {
        text = text.trim();
        if (text == "o") {
          return window.open(
            "https://ardesian.com/lists/" + cell.list.name,
            "_blank",
          );
        }

        if (/^-\d+$/.test(text)) {
          const num = parseInt(text.match(/\d+/)[0]);
          return togglePending(renderedNames()[num - 1]);
        }

        let data = { message: text };
        if (/^\d+-\d+$/gi.test(text)) {
          data.swap = true;
        } else if (/^\d+\^\d*$/gi.test(text)) {
          data.move = true;
        } else if (/^\d+\s+\w+/gi.test(text)) {
          data.rename = true;
        } else {
          data.add = text;
          delete data.message;
        }

        this.socket.send(data);
      },
    });
  }
}
