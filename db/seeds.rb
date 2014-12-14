# # This file should contain all the record creation needed to seed the database with its default values.
# # The data can then be loaded with the rake db:seed (or created alongside the db with db:setup).
# #
# # Examples:
# #
# #   cities = City.create([{ name: 'Chicago' }, { name: 'Copenhagen' }])
# #   Mayor.create(name: 'Emanuel', city: cities.first)
FlashCard.create(
  title: "Rocco's Flash Cards!",
  body: "You've flipped the card! On the back, you can store much more information that elaborates on the front side hints. As a recipe card, the directions can be saved on the back while the ingredients are kept on the front and the title is the name of the recipe.",
  pin: 11111
)
FlashCard.find(1).lines[0].update_attributes(
  text: "Click the rotate button to flip the card.",
  center: false
)
FlashCard.find(1).lines[1].update_attributes(
  text: "Or click the Edit button to change the text!",
  center: false
)
FlashCard.find(1).lines[3].update_attributes(
  text: "Center text by clicking the 'c' at the end.",
  center: true
)

FlashCard.create(
  title: "Error Card",
  body: "I'm not sure exactly what happened, but something somehow broke and you have been redirected to this card. This could have been caused if you deleted the last card in a batch or somehow broke the system in some other way. If the latter is true, please let me know what happened so I can fix it!",
  pin: 11111
)
FlashCard.find(2).lines[0].update_attributes(
  text: "Something went wrong!",
  center: true
)
FlashCard.find(2).lines[1].update_attributes(
  text: "Something is broken....",
  center: false
)
FlashCard.find(2).lines[2].update_attributes(
  text: "Rocco should probably fix this.",
  center: true
)
FlashCard.find(2).lines[5].update_attributes(
  text: "Tell me what you did!",
  center: true
)

FlashCard.create(
  title: "Random Card",
  body: "This is a random card that can be edited by anybody! There is no pin on it, so feel free to edit, delete, or save it to your will!"
)
# FlashCard.find(x).lines[x].update_attributes(
#   text: "",
#   center: true
# )
