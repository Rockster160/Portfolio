export let rawVals = ["bool", "str", "num"]

export let render = function(key, data) {
  if (!key) { return templates }

  let raw = (templates[key] || (() => ""))(data)
  let div = document.createElement("div")
  div.innerHTML = raw.trim()
  return div.firstChild
}

let jsonToElem = function(json) {
  if (!json || String(json) === json) { return json } // Empty or string
  if (typeof json === "object" && json.nodeType !== undefined) { return json } // Already a node
  if (json.raw) { return json.raw } // Raw html
  for (let [type, data] of Object.entries(json)) {
    let element = document.createElement(type)
    if (String(data) === data) {
      // When the value is a string, just set the classlist to that for quickness
      element.classList.add(...data.split(" "))
      return element
    }
    for (let [attrk, attrv] of Object.entries(data)) {

      if (!!attrv && attrv instanceof Function) {
        attrv = attrv()
      }
      switch (attrk) {
        case "class": element.classList.add(...attrv.split(" ")); break;
        case "content":
          if (Array.isArray(attrv)) {
            attrv.forEach(function(obj) { element.appendChild(jsonToElem(obj)) })
          } else {
            element.innerHTML = attrv
          }
          break;
        default: element.setAttribute(attrk, attrv)
      }
    }

    return element
  }
}

export let templates = {
  bool: () => `<label class="switch raw-input"><input type="checkbox" name="bool-{}"><span class="slider"></span></label>`,
  str:  () => `<input type="text" name="str-{}" placeholder="Hello, World!" class="raw-input">`,
  num:  () => `<input type="number" name="num-{}" placeholder="#" class="raw-input">`,
  date: () => `<input type="date" name="date-{}" class="raw-input">`,

  block: (key, existingdata) => {
    let schemaNode = document.querySelector(`[data-type="${key}"]`)
    let [_, schema] = JSON.parse(schemaNode.getAttribute("data"))

    let a = jsonToElem({
      div: {
        class: "list-item-container ui-draggable ui-draggable-handle",
        content: [
          { div: {
            class: "list-item-handle",
            content: [{ i: "fa fa-ellipsis-v" }]
          } },
          { span: {
            class: "list-item nohover",
            data: schemaNode.getAttribute("data"),
            content: function() {
              let elms = []

              elms.push({ span: { class: "delete", content: [{ i: "fa fa-trash" }] } })
              elms.push({ span: { class: "type", content: key } })
              if (existingdata.token) { elms.push({ span: { class: "token", content: existingdata.token } }) }
              schema.forEach(function(data, idx) {
                if (data.return) { elms.push({ span: { class: "return", blocktype: data.return, content: `=&gt; ${data.return}` } }) }
              })
              let filler = existingdata?.data || []

              elms.push({ span: {
                class: "item-name",
                content: function() {
                  let items = []
                  let idx = 0
                  schema.filter(obj => !obj.return).forEach(function(data) {
                    let fillitem = filler[idx] || {}
                    if (Array.isArray(data)) {
                      items.push({ select: {
                        content: data.map(function(item) {
                          return { option: {
                            name: item,
                            content: item,
                          } }
                        })
                      } })
                    }

                    if (data == "content") {
                      // Add the data as a `data-tasks` to get added in another loop
                      let tasks_data = []
                      if (key == "raw.array") {
                        tasks_data = filler
                      } else {
                        tasks_data = fillitem
                      }
                      items.push({ div: { class: "tasks", "data-tasks": JSON.stringify(tasks_data) } })
                    } else if (String(data) === data) {
                      items.push({ span: { content: data } })
                      return // Skip incrementing the idx
                    } else if (data.block) {
                      items.push({ span: {
                        class: "select-wrapper",
                        content: function() {
                          let children = []
                          if (data.label) { children.push({ label: { for: `${existingdata.token}[${idx}]`, content: data.label } }) }
                          children.push({ select: {
                            id: `${existingdata.token}[${idx}]`,
                            type: "select",
                            class: "block-select",
                            unattached: true,
                            blocktype: data.block,
                            content: function() {
                              let opts = []
                              if (data.optional) { opts.push({ option: { value: "", content: "{None}" } }) }
                              if (fillitem.option != "input" && rawVals.indexOf(data.block) >= 0) {
                                opts.push({ option: { value: "input", content: "input" } })
                              }
                              if (fillitem.option) {
                                opts.push({ option: {
                                  value: fillitem.option, selected: true, content: fillitem.option
                                } })
                              }
                              return opts
                            }
                          } })
                          if (fillitem.option == "input") {
                            let input = render(data.block)
                            let field = input.nodeName == "INPUT" ? input : input.querySelector("input")
                            if (!field) { debugger }
                            switch (field.type) {
                              case "checkbox": field.checked = fillitem.raw; break;
                              default: field.value = fillitem.raw
                            }

                            children.push(input)
                          }
                          return children
                        }
                      } })
                    }
                    idx += 1
                  })
                  return items
                }
              } })

              return elms
            }
          } },
        ]
      }
    })
    console.log(a);
    // debugger
    return a
  }
}
