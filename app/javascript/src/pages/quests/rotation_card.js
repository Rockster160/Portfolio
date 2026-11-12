// A rotation quest's card: the week, Monday first, with each day's pick and
// any extras under it, and below it every option. Tap a day to choose it
// (today to start with), then tap an option to record it on that day; tap the
// same option again to take it back.

import QuestRules from "./rules";
import QuestRotation from "./rotation";
import { renderIconValue } from "../../icon_picker";

const LETTERS = ["S", "M", "T", "W", "T", "F", "S"];

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

// An option with no icon shows its initials, so every one has a face.
function optionMark(option, className) {
  const mark = el("span", `qr-mark ${className || ""}`.trim());
  mark.title = option.name || "";
  renderIconValue(mark, option.icon || "");
  if (!mark.childNodes.length) mark.appendChild(el("span", "qr-initials", initials(option.name)));
  return mark;
}

function initials(name) {
  return String(name || "?").split(/\s+/).filter(Boolean).slice(0, 2).map(w => w[0]).join("").toUpperCase();
}

export function createRotationCard({ item, getBoard, getToday, onToggle, onEdit }) {
  let current = item;
  let selectedKey = null;
  let shownToday = null;

  const card = el("section", "quests-rotation");
  card.dataset.rotationId = item.id;
  const head = el("button", "qr-head");
  head.type = "button";
  const headIcon = el("span", "qr-head-icon");
  const headName = el("span", "qr-head-name");
  head.append(headIcon, headName);
  const week = el("div", "qr-week");
  const options = el("div", "qr-options");
  const legend = el("div", "qr-legend");
  card.append(head, week, options, legend);

  head.addEventListener("click", () => onEdit(current));

  week.addEventListener("click", e => {
    const day = e.target.closest("[data-day]");
    if (!day) return;
    selectedKey = day.dataset.day;
    render(current);
  });

  options.addEventListener("click", e => {
    const button = e.target.closest("[data-option]");
    if (button) onToggle(current, selectedDate(), button.dataset.option);
  });

  function selectedDate() {
    const days = QuestRotation.weekDays(getToday());
    return days.find(d => QuestRules.dayKey(d) === selectedKey) || getToday();
  }

  function renderWeek(board, today) {
    const todayKey = QuestRules.dayKey(today);
    const selected = QuestRules.dayKey(selectedDate());
    week.replaceChildren(...QuestRotation.weekDays(today).map(date => {
      const key = QuestRules.dayKey(date);
      const column = el("button", "qr-day");
      column.type = "button";
      column.dataset.day = key;
      column.classList.toggle("today", key === todayKey);
      column.classList.toggle("future", key > todayKey);
      column.classList.toggle("selected", key === selected);
      column.appendChild(el("span", "qr-letter", LETTERS[date.getDay()]));

      const slot = el("span", "qr-main");
      const main = QuestRotation.findOption(current, QuestRotation.mainOn(board, current, date));
      if (main) slot.appendChild(optionMark(main));
      else if (key === selected) slot.appendChild(el("span", "qr-waiting", "•••"));
      else slot.appendChild(el("span", "qr-dot"));
      column.appendChild(slot);

      const extras = el("span", "qr-extras");
      QuestRotation.extrasOn(board, current, date).forEach(id => {
        extras.appendChild(optionMark(QuestRotation.findOption(current, id), "small"));
      });
      column.appendChild(extras);
      return column;
    }));
  }

  function renderOptions(board, today) {
    const date = selectedDate();
    const main = QuestRotation.mainOn(board, current, date);
    const extras = QuestRotation.extrasOn(board, current, date);
    const standings = QuestRotation.standings(board, current, today);
    options.replaceChildren(...standings.map(option => {
      const button = el("button", "qr-option");
      button.type = "button";
      button.dataset.option = option.id;
      button.classList.toggle("picked", option.picked);
      button.classList.toggle("chosen", option.id === main || extras.includes(option.id));
      button.appendChild(optionMark(option));
      if (QuestRotation.isExtra(option)) button.appendChild(el("span", "qr-badge extra", "⊕"));
      else if (option.due) button.appendChild(el("span", "qr-badge due", "✱"));
      return button;
    }));

    const anyExtra = standings.some(o => QuestRotation.isExtra(o));
    const anyDue = standings.some(o => o.due);
    legend.replaceChildren(
      ...(anyDue ? [el("div", "qr-legend-row", "✱ Missed last week — due this week")] : []),
      ...(anyExtra ? [el("div", "qr-legend-row", "⊕ Can turn up any day, alongside the day's pick")] : []),
    );
    if (!standings.length) options.appendChild(el("p", "qr-empty", "No options yet — tap the title to add some."));
  }

  function render(item) {
    current = item;
    const board = getBoard();
    const today = getToday();
    // A new game day starts on itself, whatever was chosen yesterday.
    const todayKey = QuestRules.dayKey(today);
    if (todayKey !== shownToday) selectedKey = todayKey;
    shownToday = todayKey;

    headIcon.dataset.value = current.icon || "";
    renderIconValue(headIcon, current.icon || "");
    headName.textContent = current.name || "Rotation";
    renderWeek(board, today);
    renderOptions(board, today);
  }

  return { node: card, render };
}
