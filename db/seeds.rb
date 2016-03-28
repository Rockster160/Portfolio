LitterTextReminder.create
FlashCard.create(
  title: "Rocco's Flash Cards!",
  body: "You've flipped the card! On the back, you can store much more information that elaborates on the front side hints. As a recipe card, the directions can be saved on the back while the ingredients are kept on the front and the title is the name of the recipe.",
  pin: 11111
)
FlashCard.last.lines[0].update_attributes(
  text: "Click the rotate button to flip the card.",
  center: false
)
FlashCard.last.lines[1].update_attributes(
  text: "Or click the Edit button to change the text!",
  center: false
)
FlashCard.last.lines[3].update_attributes(
  text: "Center text by clicking the 'c' at the end.",
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
