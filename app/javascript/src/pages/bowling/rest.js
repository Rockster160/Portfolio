export default class Rest {
  static controllers = {}

  static abort(id) { try { Rest.controllers[id]?.abort() } catch (e) {} }

  static submit(form, opts) {
    opts = opts || {}

    let method = opts.method || form.method
    let url = opts.url || form.action
    let params = opts.params || new FormData(form)

    return this.request(method, url, params)
  }

  static request(method, url, params, opts) {
    opts = opts || {}

    let id = `${method}:${url}`
    this.abort(id)
    Rest.controllers[id] = new AbortController()

    let fetchOpts = {
      signal: Rest.controllers[id].signal,
      method: method,
    }
    if (method.toUpperCase() == "GET") {
      if (params) { url = this.encodeUrlParams(url, params) }
    } else {
      if (params) { fetchOpts.body = params }
    }

    console.log(`REQUEST:${id}`);
    return fetch(url, fetchOpts).then(function(res) {
      Rest.controllers[id] = null
      if (!res.ok) { throw new Error("Request failed", res) }

      const contentType = res.headers.get("Content-Type")
      if (contentType && contentType.includes("application/json")) {
        return res.json()
      } else {
        return res.text()
      }
    }, err => console.error("Error:", err))
  }

  static get(url, params) {
    return this.request("GET", url, params)
  }

  static post(url, params) {
    return this.request("POST", url, params)
  }

  static patch(url, params) {
    return this.request("PATCH", url, params)
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
