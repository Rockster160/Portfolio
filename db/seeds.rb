# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rake db:seed (or created alongside the db with db:setup).
#
# Examples:
#
#   cities = City.create([{ name: 'Chicago' }, { name: 'Copenhagen' }])
#   Mayor.create(name: 'Emanuel', city: cities.first)

FlashCard.create(id: 0,
  title: "Rocco's Flash Cards!",
  line: [
      ["Click the rotate button to flip the card.",0],
      ["",0],
      ["",0],
      ["Center text by clicking the 'c' at the end.",1],
      ["",0],
      ["",0],
      ["",0],
      ["",0]
      ],
  body: "You've flipped the card! On the back, you can store much more information that elaborates on the front side hints. As a recipe card, the directions can be saved on the back while the ingredients are kept on the front and the title is the name of the recipe."
)
