let counter = 0
function genCounter() {
  return counter += 1
}

export let toMd = function(text) {
  if (!text || typeof text !== "string") { return text }

  const hold = {}

  return text.replaceAll(/<svg.*?<\/svg>/migu, (match) => {
      const id = genCounter()
      hold[id] = match
      return `__TOKEN${id}__`
  }).replaceAll(/([\p{So}\p{Sk}\p{Sm}\p{Sc}\p{S}\p{C}]+)/gu, (match) => {
    return emoji(match)
  }).replaceAll(/\[ico (.*?)(( [\w-]+: .*?)*)\]/gu, (match, p1, p2) => {
    return emoji(null, `ti ti-${p1}`, { style: p2 })
  }).replaceAll(/\[img (.*?)\]/gu, (match, p1) => {
    return img(p1)
  }).replaceAll(/(\\n|\n)/g, (match) => {
    return "<br>"
  }).replaceAll(/__TOKEN(\d+)__/g, (match, id) => {
    return hold[id] || match
  })
}

let img = function(filename) {
  if (!filename.startsWith("http") && !filename.startsWith("/")) {
    filename = `/${filename}`
  }
  if (!filename.includes(".")) {
    filename = `${filename}.png`
  }
  return emoji(`<img src='${filename}'/>`)
}

let emoji = function(icon, extraClasses = null, { style } = {}) {
  const ele = document.createElement("i")
  ele.textContent = icon
  ele.className = `emoji ${extraClasses || ''}`
  if (style) {
    ele.setAttribute("style", style)
  }

  return ele.outerHTML
}
