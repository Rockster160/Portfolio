import { htmlToNode } from "./form.js"

export let toMd = function(text) {
  return text
  .replace(/([\p{So}\p{Sk}\p{Sm}\p{Sc}\p{S}\p{C}]+)/gu, (match) => {
    return emoji(match)
  })
  .replace(/\[ico (.*?)(( [\w-]+: .*?)*)\]/gu, (match, p1, p2) => {
    return emoji(null, `ti ti-${p1}`, { style: p2 })
  })
  .replace(/\[img (.*?)\]/gu, (match, p1) => {
    return img(p1)
  })
}

let img = function(filename) {
  return emoji(`<img src='/${filename}.png'/>`)
}

let emoji = function(icon, extraClasses = null, { style } = {}) {
  const ele = document.createElement("i")
  ele.textContent = icon
  ele.className = `emoji ${extraClasses || ''}`
  if (style) {
    ele.setAttribute("style", style)
    // Object.keys(style).forEach((key) => {
    //   ele.style[key] = style[key]
    // })
  }

  return ele.outerHTML
}
