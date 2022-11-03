import { JsChance } from "./js_chance"

export let parser = new JsChance(`
token
  [adjective].[object].[place]
  [animal].[verb].[food]

food
  apple
  bisquit
  carrot
  danish
  eclair
  wine

animal
  aphid
  cat
  dog
  monkey
  shrimp
  zebra

object
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

place
  saloon
  bed
  car
  desert
  ocean
  town

verb
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

adjective
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
