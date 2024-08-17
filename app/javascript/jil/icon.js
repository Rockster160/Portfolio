export function fa(ico) {
  let i = document.createElement("i")
  ico.split(" ").forEach(klass => i.classList.add(klass == "fa" ? "fa" : `fa-${klass}`))
  return i
}

export function faStack(top, bot) {
  let stack = document.createElement("span")
  stack.classList.add("fa-stack")

  let topEle = fa(top)
  topEle.classList.add("fa-stack-1x")
  stack.appendChild(topEle)

  let botEle = fa(bot)
  botEle.classList.add("fa-stack-1x")
  stack.appendChild(botEle)

  return stack
}
