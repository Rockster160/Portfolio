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
  }).replaceAll(/\[hr\]/gi, '<hr>')
  .replaceAll(/\[bg (.*?)\](.*?)\[\/bg\]/gi, '<span style="background-color: $1;">$2</span>')
  .replaceAll(/\[color (.*?)\](.*?)\[\/color\]/gi, '<span style="color: $1;">$2</span>')
  .replaceAll(/\[bold\](.*?)\[\/bold\]/gi, '<b>$1</b>')
  .replaceAll(/\[ani \"(.*?)\"\]/gi, '<textanimate steps="$1"> </textanimate>')
  .replaceAll(/\[ico (.*?)(( [\w-]+: .*?)*)\]/gu, (match, p1, p2) => {
    return emoji(null, `ti ti-${p1}`, { style: p2 })
  }).replaceAll(/\[img (.*?)\]/gu, (match, p1) => {
    return img(p1)
  }).replaceAll(/\[plain (.*?)\]\((.*?)\)/gi, '<a href="$2" target="_blank" rel="noopener noreferrer" class="dash-link dash-link-plain">$1</a>')
  .replaceAll(/\[((?!plain )[^\]]*?)\]\((.*?)\)/gi, '<a href="$2" target="_blank" rel="noopener noreferrer" class="dash-link">$1</a>')
  .replaceAll(/(\\n|\n)/g, (match) => {
    return "<br>"
  }).replaceAll(/__TOKEN(\d+)__/g, (match, id) => {
    return hold[id] || match
  })
}

setInterval(function() {
  document.querySelectorAll("textanimate").forEach(function(ele) {
    let steps = ele.getAttribute("steps").split("")
    let current_step = parseInt(ele.getAttribute("step") || 0)
    let next_step = (current_step + 1) % steps.length
    ele.textContent = steps[next_step]
    ele.setAttribute("step", next_step)
  })
}, 100)

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
