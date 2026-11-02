// Card sizes. A page sets the size its cards start at (`meta.card_size`),
// and any timer can override it with its own `width` — 0 means "follow
// the page". Both store the same scale, so one lookup reads either.

export const CARD_SIZES = [
  { value: 1, key: "s",    label: "S",    title: "Small" },
  { value: 2, key: "m",    label: "M",    title: "Medium" },
  { value: 3, key: "l",    label: "L",    title: "Large" },
  { value: 4, key: "full", label: "Full", title: "Full width" },
];

export const DEFAULT_CARD_SIZE = 2;

function known(n) {
  return CARD_SIZES.some((s) => s.value === n);
}

export function pageCardSize(page) {
  const n = parseInt(page?.meta?.card_size, 10);
  return known(n) ? n : DEFAULT_CARD_SIZE;
}

export function timerCardSize(timer, page) {
  const own = parseInt(timer?.width, 10);
  return known(own) ? own : pageCardSize(page);
}

export function cardSizeKey(n) {
  return CARD_SIZES.find((s) => s.value === n)?.key || "m";
}
