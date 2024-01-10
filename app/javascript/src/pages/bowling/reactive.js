export default class Reactive {
  constructor(element) {
    this.element = element
  }

  bool(boolname, callback) {
    this.accessor(boolname, callback)
    this[`${boolname}Toggle`] = () => { this[boolname] = !this[boolname] }
  }

  accessor(propName, callback) {
    let snake = propName.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase()
    // The below stops the getter from being redefined every time a new instance is created
    let getter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(this), propName)
    if (getter && typeof getter.get === "function") { return }

    Object.defineProperty(this.constructor.prototype, propName, {
      get() { return this[snake] },
      set(value) {
        this[snake] = value
        if (callback && typeof(callback) === "function") { callback.call(this, value) }
      },
    })
  }

  elementAccessor(propName, selector, attr, callback) {
    // Fix arg positioning
    // accessor("myAccessor", ".selector", fn())
    if (attr && typeof(attr) === "function") {
      callback = attr
      attr = undefined
    }

    let getEleVal = function() {
      let ele = selector === null ? this.element : this.element.querySelector(selector)
      ele = ele || this.element || document

      if (attr === undefined) {
        return ele.tagName == "INPUT" ? ele.value : ele.innerText
      } else if (attr === "value") {
        return ele.tagName == "INPUT" ? ele.value : ele.getAttribute(attr)
      } else {
        return ele.tagName == "INPUT" ? ele[attr] : ele.getAttribute(attr)
      }
    }
    let setEleVal = function(value) {
      let eles = selector === null ? [this.element] : this.element.querySelectorAll(selector)
      eles.forEach(ele => {
        if (attr === undefined || attr === "value") {
          if (ele.tagName == "INPUT") {
            ele.value = value
          } else {
            attr === "value" ? ele.setAttribute(attr, value) : ele.innerText = value
          }
        } else {
          if (ele.tagName == "INPUT") {
            ele[attr] = value
          } else {
            ele.setAttribute(attr, value)
          }
        }
      })

      if (callback && typeof(callback) === "function") { callback.call(this, value) }
    }

    // Add page listeners to trigger the "set" callback on changes
    let self = this
    this.element.addEventListener("change", function(evt) {
      if (!evt.target.closest(selector)) { return }

      setEleVal.call(self, getEleVal.call(self))
      // self[propName] = self[propName] // Call the setter with the getter
    })

    let getter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(this), propName)
    if (getter && typeof getter.get === "function") { return }

    Object.defineProperty(this.constructor.prototype, propName, {
      get() { return getEleVal.call(this) },
      set(value) { setEleVal.call(this, value) },
    })
  }
}
