export default class Reactive {
  constructor(element) {
    this.element = element
  }

  bool(boolname, default_val, callback) {
    this.accessor(boolname, default_val, callback)
    this[`${boolname}Toggle`] = () => { this[boolname] = !this[boolname] }
  }

  static parse(val) {
    try {
      return JSON.parse(val)
    } catch (e) {
      return val || null
    }
  }

  accessor(propName, default_val, callback) {
    if (default_val && typeof(default_val) === "function") {
      callback = default_val
      default_val = undefined
    }

    let snake = "_" + propName.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase()
    if (!default_val === undefined) { this[snake] = default_val }
    // The below stops the getter from being redefined every time a new instance is created
    let getter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(this), propName)
    if (getter && typeof getter.get === "function") { return }

    Object.defineProperty(this.constructor.prototype, propName, {
      get() { return Reactive.parse(this[snake]) },
      set(value) {
        this[snake] = value
        if (callback && typeof(callback) === "function") { callback.call(this, value) }
      },
    })
  }

  elementAccessor(propName, selector, attr, callback) {
    // Fix arg positioning
    // elementAccessor("myAccessor", ".selector", fn())
    if (attr && typeof(attr) === "function") {
      callback = attr
      attr = undefined
    }

    let getEleVal = function() {
      let ele = selector === null ? this.element : this.element.querySelector(selector)
      ele = ele || this.element || document

      if (attr === undefined) {
        return Reactive.parse(ele.tagName == "INPUT" ? ele.value : ele.innerText)
      } else if (attr === "value") {
        return Reactive.parse(ele.tagName == "INPUT" ? ele.value : ele.getAttribute(attr))
      } else {
        return Reactive.parse(ele.tagName == "INPUT" ? ele[attr] : ele.getAttribute(attr))
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

      setEleVal.call(self, getEleVal.call(self)) // Call the setter with the getter
    })

    let getter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(this), propName)
    if (getter && typeof getter.get === "function") { return }

    Object.defineProperty(this.constructor.prototype, propName, {
      get() { return Reactive.parse(getEleVal.call(this)) },
      set(value) { setEleVal.call(this, value) },
    })
  }
}
