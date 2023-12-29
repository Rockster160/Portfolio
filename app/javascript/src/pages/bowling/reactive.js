export default class Reactive {
  constructor(element) {
  }

  accessor(propName, selector, attr, callback) {
    // Fix arg positioning
    if (selector && typeof(selector) === "function") {
      callback = selector
      selector = undefined
      attr = undefined
    }
    if (attr && typeof(attr) === "function") {
      callback = attr
      attr = undefined
    }
    if (!attr) {
      attr = selector
      selector = undefined
    }
    // The below stops the getter from being redefined every time a new instance is created
    let getter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(this), propName)
    if (getter && typeof getter.get === "function") { return }

    Object.defineProperty(this.constructor.prototype, propName, {
      get() {
        let ele = selector ? this.element.querySelector(selector) : this.element
        if (ele.tagName == "INPUT" || ele.hasAttribute(attr)) {
          return ele.getAttribute(attr)
        } else {
          return ele.innerText
        }
      },
      set(value) {
        let eles = selector ? this.element.querySelectorAll(selector) : [this.element]
        eles.forEach(ele => {
          if (ele.tagName == "INPUT" || ele.hasAttribute(attr)) {
            ele.setAttribute(attr, value)
            if (ele.type == "checkbox" && !value) { ele.removeAttribute("checked") }
          } else {
            ele.innerText = value
          }
        })

        if (callback && typeof(callback) === "function") { callback.call(this, value) }
      },
    })
  }

  bool(boolname, callback) {
    let snake = boolname.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase()
    Object.defineProperty(this.constructor.prototype, boolname, {
      get() { return !!this[snake] },
      set(value) {
        this[snake] = value
        if (callback && typeof(callback) === "function") { callback.call(this, value) }
      },
    })
    this[`${boolname}Toggle`] = () => { this[boolname] = !this[boolname] }
  }
}
