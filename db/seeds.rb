# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rake db:seed (or created alongside the db with db:setup).
#
# Examples:
#
#   cities = City.create([{ name: 'Chicago' }, { name: 'Copenhagen' }])
#   Mayor.create(name: 'Emanuel', city: cities.first)

FlashCard.create(id: 0, #Default
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

FlashCard.create(id: 1, #Error
  title: "Error Card",
  line: [
      ["Something went wrong!",1],
      ["Something is broken!",0],
      ["Rocco needs to fix this...",1],
      ["",0],
      ["",0],
      ["What did you do??",1],
      ["",0],
      ["",0]
      ],
  body: "Provide a bulleted list of 5 potential adaptations that might allow your organism to survive and reproduce successfully in the habitat/niche that you've descrived."
)

FlashCard.create(id: 2,
  title: "Rocco's Flash Cards!",
  line: [
      ["This is another card!",1],
      ["I successfully auto-loaded another!",0],
      ["Some text is centered and other text isn't.",1],
      ["Center text by clicking the 'c' at the end.",0],
      ["",0],
      ["",0],
      ["Hello, World!",0],
      ["",0]
      ],
  body: "Provide a bulleted list of 5 potential adaptations that might allow your organism to survive and reproduce successfully in the habitat/niche that you've descrived."
)
