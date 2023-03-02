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
        case "class":
          let klasses = attrv.replaceAll(/^ *| *$/g, "").split(" ").filter((i) => i.length > 0)
          if (klasses.length > 0) { element.classList.add(...klasses) }
          break;
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

export let shorttype = function(type) {
  switch(type) {
    case "bool":     return "T|F"; break;
    case "str":      return "str"; break;
    case "num":      return "#"; break;
    case "keyval":   return "k:v"; break;
    case "hash":     return "{}"; break;
    case "array":    return "[]"; break;
    case "date":     return "date"; break;
    case "duration": return "dur"; break;
    case "var":      return "var"; break;
    case "task":     return "tsk"; break;
    case "any":      return "any"; break;
    default:         return `&lt;unknown(${type})&gt;`
  }
}

// Still TODO:
// init dropdowns on load
// Save the dynamic value -- currently being ignored? Check `collectBlockData`
// Load the value on the next page load
// Use the dynamic value to in Jarvis::Execute
export let tokenSelector = function() {
  return jsonToElem({ select: {
    // id: `${existingdata.token}[${idx}]`,
    type: "select",
    class: `block-select`,
    unattached: true,
    blocktype: "str",
    content: function() {
      let opts = []
      // if (data.optional) { opts.push({ option: { value: "", content: `{${data.default || "None"}}` } }) }
      // bool str num allow raw entries
      // if (fillitem.option != "input" && rawVals.indexOf(data.block) >= 0) {
      //   opts.push({ option: { value: "input", content: "input" } })
      // }
      // if (fillitem.option) {
      //   opts.push({ option: {
      //     value: fillitem.option, selected: true, content: fillitem.option
      //   } })
      // }
      return opts
    }
  } })
}

export let templates = {
  bool: () => `<label class="switch raw-input"><input type="checkbox" name="bool-{}"><span class="slider"></span></label>`,
  str:  () => `<input type="text" name="str-{}" placeholder="Hello, World!" class="raw-input">`,
  num:  () => `<input type="number" name="num-{}" placeholder="#" class="raw-input">`,
  date: () => `<input type="date" name="date-{}" class="raw-input">`,

  block: (key, existingdata) => {
    let schemaNode = document.querySelector(`[data-type="${key}"]`)
    let [_, schema] = JSON.parse(schemaNode.getAttribute("data"))

    return jsonToElem({
      div: {
        class: "list-item-container ui-draggable ui-draggable-handle",
        content: [
          { div: {
            class: "list-item-handle",
            content: [{ i: "fa fa-ellipsis-v" }]
          } },
          { span: {
            class: "list-item nohover",
            token: existingdata.token,
            data: schemaNode.getAttribute("data"),
            content: function() {
              let elms = []

              elms.push({ span: { class: "delete", content: [{ i: "fa fa-trash" }] } })
              elms.push({ span: { class: "type", content: key } })
              if (existingdata.token) { elms.push({ span: { class: "token", content: existingdata.token } }) }
              schema.forEach(function(data, idx) {
                if (data.return) {
                  elms.push({ span: {
                    class: "return",
                    blocktype: data.return,
                    content: [
                      { span: { class: "return-label", content: "returns" }},
                      { span: { class: "return-type", content: data.return }}
                    ]
                  } })
                }
              })
              let filler = existingdata?.data || []

              elms.push({ span: {
                class: "item-name",
                content: function() {
                  let items = []
                  let idx = 0
                  schema.filter(obj => !obj.return).forEach(function(data) {
                    let fillitem = filler[idx] || {}
                    if (data == "content") {
                      let tasks_data = []
                      if (key == "raw.array" || key == "raw.hash") {
                        tasks_data = filler
                      } else {
                        tasks_data = fillitem
                      }
                      if (!Array.isArray(tasks_data)) { tasks_data = [tasks_data] }
                      // Add the data as a `data-tasks` to get added in another loop
                      items.push({ div: { class: "tasks", "data-tasks": JSON.stringify(tasks_data) } })
                    } else if (String(data) === data) {
                      items.push({ span: { content: data } })
                      return // Skip incrementing the idx since this isn't a user input
                    } else if (data.block && data.block != "select") {
                      items.push({ span: {
                        class: "select-wrapper",
                        blockdata: JSON.stringify(data),
                        content: function() {
                          let children = []
                          children.push({ label: {
                            for: `${existingdata.token}[${idx}]`,
                            content: [
                              { span: { class: "shorttype", content: shorttype(data.block) } },
                              { span: { class: "select-name", content: data.label || "" } },
                            ]
                          } })
                          children.push({ select: {
                            id: `${existingdata.token}[${idx}]`,
                            type: "select",
                            class: `block-select ${data.optional ? "optional" : ""}`,
                            unattached: true,
                            blocktype: data.block,
                            content: function() {
                              let opts = []
                              if (data.optional) { opts.push({ option: { value: "", content: `{${data.default || "None"}}` } }) }
                              // bool str num allow raw entries
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
                              default: field.value = (fillitem.raw || data.default || "")
                            }

                            children.push(input)
                          }
                          return children
                        }
                      } })
                    } else if (data.block && data.block == "select") {
                      // This whole block is essentially a duplicate of the next one (Array check)
                      // Ideally, these would work together to DRY up the code, but in the sake of
                      //   speed and not knowing a great way to merge these without a lot of
                      //   conditional code, going with duplicate blocks for now.
                      // We want the regular array + an option for <dynamic>
                      // When <dynamic> is selected, add a second select field which acts like a
                      //   standard str token selection (allows selecting a token like wash.sit.cat)
                      let dyn_str = "&lt;dynamic&gt;"
                      items.push({ span: {
                        class: "select-wrapper",
                        content: [{ select: {
                          class: "dynamic-select",
                          unattached: true,
                          content: [...data.values, dyn_str].map(function(item) {
                            let dynamic = item == dyn_str
                            if (fillitem.selected == item || fillitem.option == item) {
                              return { option: { value: item, selected: true, content: item, class: `${dynamic ? "dynamic-option" : ""}` } }
                            } else {
                              return { option: { value: item, content: item, class: `${dynamic ? "dynamic-option" : ""}` } }
                            }
                          })
                        } }]
                      } })
                    } else if (Array.isArray(data)) {
                      // Array of items- add a select dropdown to allow choosing an item
                      items.push({ span: {
                        class: "select-wrapper",
                        content: [{ select: {
                          content: data.map(function(item) {
                            if (fillitem.option == item) {
                              return { option: { value: item, selected: true, content: item } }
                            } else {
                              return { option: { value: item, content: item } }
                            }
                          })
                        } }]
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
  }
}
