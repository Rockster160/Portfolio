import { JsChance } from "./js_chance"

export let tokens = []
let maxtokens = 124950 // Hardcoded by calculating the permutations

// 6 + 6 + 10 + 6 + 11 + 12 = 51
// P(n,r) = P(51,3) = 124,950 possibilities
export let genUniqToken = function() {
  let token
  do { token = parser.token() } while (tokens.indexOf(token) >= 0);
  tokens.push(token)
  return token
}
export let parser = new JsChance(`
token
  [three]

three
  [category].[category].[category]

category
  [food]
  [animal]
  [object]
  [place]
  [verb]
  [adjective]

food // 5
  apple
  carrot
  danish
  eclair
  wine

animal // 6
  aphid
  cat
  dog
  monkey
  shrimp
  zebra

object // 10
  frost
  mug
  clip
  paper
  desk
  pine
  ring
  tree
  oak
  cable

place // 5
  saloon
  bed
  car
  ocean
  town

verb // 11
  stand
  sit
  wash
  push
  read
  grow
  eat
  think
  invent
  join
  goto

adjective // 12
  dirty
  clean
  heavy
  soft
  shiny
  blue
  red
  green
  yellow
  purple
  limp
  funky
`)
