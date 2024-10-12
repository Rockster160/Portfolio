import Mouse from "./mouse.js"
import Keyboard from "./keyboard.js"
import { clamp } from "./form_helpers.js"

export default class Dropdown {
  static search = []
  static get node() {
    return document.querySelector("#reference-dropdown")
  }

  static shown() { return !this.node.classList.contains("hidden") }
  static show(opts) { this.showAt(Mouse.x, Mouse.y, opts) }
  static showAt(x, y, opts) {
    this.hide(false)
    let node = this.node
    node.focus()

    this.buildOpts(node, opts)

    node.classList.remove("hidden")

    this.reposition(x, y)
    this.selectFirst()
  }
  static moveToMouse() {
    if (!Mouse.x || !Mouse.y) { return }
    this.reposition(Mouse.x, Mouse.y)
  }
  static reposition(x, y) {
    const node = this.node
    const dropdownRect = node.getBoundingClientRect()
    const pageWidth = document.documentElement.clientWidth - 20 // 20 to pad page edges
    const pageHeight = document.documentElement.clientHeight - 20 // 20 to pad page edges

    let height = dropdownRect.height
    if (y + height > pageHeight) { // Overflowing vertically
      height = pageHeight - y
      const minOverflowHeight = clamp(200, 200, pageHeight) // Cap at page height
      if (height < minOverflowHeight && dropdownRect.height > minOverflowHeight) {
        height = minOverflowHeight
        y = pageHeight - height
      }
    }

    let width = dropdownRect.width
    x = x - (width/2) // Center on the desired x
    if (x + width > pageWidth) { // Overflowing horizontally
      width = pageWidth - x
      const minOverflowWidth = clamp(200, 200, pageWidth) // Cap at page width
      if (width < minOverflowWidth && dropdownRect.width > minOverflowWidth) {
        width = minOverflowWidth
        x = pageWidth - width
      }
    }

    node.style.top = `${y}px`
    node.style.left = `${x}px`
    node.style.height = `${height}px`
    node.style.width = `${width}px`
  }

  static buildOpts(node, opts) {
    opts.forEach(opt => {
      const ul = node.querySelector("ul")
      const li = document.createElement("li")

      if (Array.isArray(opt)) {
        li.classList.add("horz-list")

        const nestedUl = document.createElement("ul")
        opt.forEach(nopt => {
          const nli = document.createElement("li")
          if (nopt.text) { nli.innerText = nopt.text }
          if (nopt.icon) { nli.appendChild(nopt.icon) }
          if (nopt.title) { nli.title = nopt.title }
          if (nopt.callback && typeof nopt.callback === "function") {
            nli.addEventListener("select", (evt) => {
              evt.preventDefault()
              nopt.callback()
              Dropdown.hide()
            })
          }
          nestedUl.appendChild(nli)
        })
        li.appendChild(nestedUl)
      } else {
        if (opt.upcoming) { li.classList.add("upcoming") }
        if (opt.text) { li.innerText = opt.text }
        if (opt.icon) { li.appendChild(opt.icon) }
        if (opt.title) { li.title = opt.title }
        if (opt.callback && typeof opt.callback === "function") {
          li.addEventListener("select", (evt) => {
            evt.preventDefault()
            opt.callback()
            Dropdown.hide()
          })
        }
      }
      ul.appendChild(li)
    })
  }

  static hide(clearMoveStatement=true) {
    this.search = []
    this.node.classList.add("hidden")
    this.node.querySelectorAll("li").forEach(li => li.remove())

    this.node.style.height = "auto"
    this.node.style.width = "200px"
    if (clearMoveStatement) { window.moveStatement = null }
  }

  static removeSelected() {
    document.querySelectorAll(".dropdown-hovered-item").forEach(item => item.classList.remove("dropdown-hovered-item"))
  }

  static selectFirst() {
    if (document.querySelector(".dropdown-hovered-item")) { return }
    this.allItems(":scope > ul > li:not(:has(ul)):not(.hidden)")[0]?.classList?.add("dropdown-hovered-item")
  }

  static allItems(selector) {
    return Array.from(Dropdown.node.querySelectorAll(selector || "li:not(:has(ul)):not(.hidden)"))
  }

  static firstItem(selector) {
    if (!Dropdown.shown()) { return }
    return Dropdown.allItems(selector)[0]
  }
  static lastItem(selector) {
    if (!Dropdown.shown()) { return }
    const list = Dropdown.allItems(selector)
    return list[list.length - 1]
  }

  static previousItem(item, selector) {
    if (!Dropdown.shown()) { return }
    const list = Dropdown.allItems(selector)
    if (!item) { return Dropdown.lastItem() }
    let idx = list.indexOf(item) - 1
    if (idx < 0) { idx = list.length - 1 }
    if (idx > list.length - 1) { idx = 0 }
    return list[idx]
  }
  static nextItem(item, selector) {
    if (!Dropdown.shown()) { return }
    const list = Dropdown.allItems(selector)
    if (!item) { return Dropdown.firstItem() }
    let idx = list.indexOf(item) + 1
    if (idx < 0) { idx = list.length - 1 }
    if (idx > list.length - 1) { idx = 0 }
    return list[idx]
  }

  static updateSearch() {
    // function levenshteinDistance(a, b) {
    //   const matrix = Array.from({ length: b.length + 1 }, (_, i) => Array(a.length + 1).fill(0));
    //
    //   for (let i = 0; i <= a.length; i++) matrix[0][i] = i;
    //   for (let j = 0; j <= b.length; j++) matrix[j][0] = j;
    //
    //   for (let j = 1; j <= b.length; j++) {
    //     for (let i = 1; i <= a.length; i++) {
    //       const cost = a[i - 1] === b[j - 1] ? 0 : 1;
    //       matrix[j][i] = Math.min(
    //         matrix[j - 1][i] + 1,    // Deletion
    //         matrix[j][i - 1] + 1,    // Insertion
    //         matrix[j - 1][i - 1] + cost // Substitution
    //       );
    //     }
    //   }
    //
    //   return matrix[b.length][a.length];
    // }
    // function sortByClosestMatch(list, searchStr) {
    //   return list.sort((a, b) => levenshteinDistance(searchStr, a) - levenshteinDistance(searchStr, b));
    // }

    this.allItems("li:not(:has(ul))").forEach((item, idx) => {
      if (!item.hasAttribute("sort-idx")) { item.setAttribute("sort-idx", idx+1) }

      let text = item.textContent.toLowerCase()
      const match = this.search.every(letter => {
        let idx = text.indexOf(letter.toLowerCase())
        if (idx < 0) { return false }
        text = text.slice(idx)
        return true
      })
      if (match) {
        item.classList.remove("hidden")
      } else {
        item.classList.add("hidden")
      }
    })
    this.removeSelected()
    this.selectFirst()
  }
}

document.addEventListener("mouseover", (evt) => {
  const hovered = evt.target.closest("li")
  if (!hovered) { return }
  if (hovered.closest(".dropdown-hovered-item")) { return }

  Dropdown.removeSelected()
  hovered.classList.add("dropdown-hovered-item")
})

document.addEventListener("click", function(evt) {
  if (evt.target.tagName != "LI") { return }
  if (!evt.target.closest("#reference-dropdown")) { return }

  evt.target.dispatchEvent(new CustomEvent("select", {
    bubbles: true,
  }))
})
Keyboard.on("Enter", (evt) => {
  const item = document.querySelector(".dropdown-hovered-item")
  if (item) {
    evt.preventDefault()
    evt.stopPropagation()
    Keyboard.clear()
    item.dispatchEvent(new CustomEvent("select", {
      bubbles: true,
    }))
  }
})
Keyboard.on("↑", (evt) => {
  if (Dropdown.shown()) {
    evt.preventDefault()

    const item = document.querySelector(".dropdown-hovered-item")
    const previous = Dropdown.previousItem(item)
    if (previous) {
      item?.classList?.remove("dropdown-hovered-item")
      previous.classList.add("dropdown-hovered-item")
      previous.scrollIntoViewIfNeeded()
    }
  }
})
Keyboard.on("↓", (evt) => {
  if (Dropdown.shown()) {
    evt.preventDefault()

    const item = document.querySelector(".dropdown-hovered-item")
    const next = Dropdown.nextItem(item)
    if (next) {
      item?.classList?.remove("dropdown-hovered-item")
      next.classList.add("dropdown-hovered-item")
      next.scrollIntoViewIfNeeded()
    }
  }
})
document.addEventListener("keydown", (evt) => {
  if (Dropdown.shown()) {
    if (evt.metaKey) {
      if (evt.key == "Backspace" || evt.key == "Delete") { Dropdown.search = [] }
      Dropdown.updateSearch()
      return
    }
    if (evt.key == "Backspace" || evt.key == "Delete") {
      Dropdown.search.pop()
      Dropdown.updateSearch()
    }
    if (/^[a-zA-Z0-9]$/.test(evt.key)) {
      Dropdown.search.push(evt.key)
      Dropdown.updateSearch()
    }
    if (evt.key == "Escape") { Dropdown.hide(false) }
  }
})
