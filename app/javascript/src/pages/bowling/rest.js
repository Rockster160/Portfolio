export default class Rest {
  static controllers = {}

  static abort(method) { this.controllers[method]?.abort() }

  static async request(method, url, params, callback) {
    if (params && typeof(params) === "function") {
      callback = params
      params = undefined
    }

    this.abort(method)
    this.controllers[method] = new AbortController()
    let fetchOpts = {
      signal: this.controllers[method].signal,
      method: method,
      // headers: { "Content-Type": "application/json" },
    }
    if (method == "GET") {
      if (params) { url = this.encodeUrlParams(url, params) }
    } else {
      if (params) { fetchOpts.body = params }
    }

    await fetch(url, fetchOpts).then((res) => {
      if (res.ok) {
        res.json().then((json) => {
          if (callback && typeof callback === "function") { callback(json) }
        })
      }
      this.controllers[method] = null
    }).catch((e) => {})
  }

  static async get(url, params, callback) {
    await this.request("GET", url, params, callback)
  }

  static async post(url, params, callback) {
    await this.request("POST", url, params, callback)
  }

  static async patch(url, params, callback) {
    await this.request("PATCH", url, params, callback)
  }

  static encodeUrlParams(url, params) {
    const queryString = Object.keys(params).map(key => {
      const value = params[key]
      if (Array.isArray(value)) {
        return value.map(item => `${encodeURIComponent(key)}[]=${encodeURIComponent(item)}`).join("&")
      } else if (value === undefined || value === null) {
        return
      } else if (typeof value === "object") {
        return this.encodeUrlParams("", { [key]: value }).substr(1)
      } else {
        return `${encodeURIComponent(key)}=${encodeURIComponent(value)}`
      }
    }).join("&")

    const separator = url.includes("?") ? "&" : "?"
    return `${url}${separator}${queryString}`
  }
}
