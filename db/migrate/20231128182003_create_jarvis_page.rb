class CreateJarvisPage < ActiveRecord::Migration[7.0]
  def change
    create_table :jarvis_pages do |t|
      t.belongs_to :user
      t.jsonb :blocks

      t.timestamps
    end

    User.me.jarvis_page.update(blocks: [
      { type: :tesla },
      { type: :garage },
      {
        logo: "💊",
        buttons: [
          { log: :Vitamins },
          { log: "D-AmphXR 20mg" },
          { log: "D-Amph 20mg" },
          { log: "Pristiq 25mg" },
          { log: "AdderallXR 15mg" },
          { log: "AdderallXR 20mg" },
          { log: "Buspirone 20mg" },
          { log: "Relaxium 1" },
          { log: "Relaxium 2" },
          { log: "NQ" },
          { log: "NQ Half" },
          { log: "Methyl 10mg" },
          { log: "Methyl 20mg" },
          { log: "Escital 20mg" },
          { log: "X" },
          { log: "Z {{}}", logo: "Z" },
        ]
      },
      {
        logo: "[ico fa-paper_plane width: 32px;]",
        buttons: [
          { logo: "🔄", page: ".reload" },
          { logo: "💧", log: :Water },
          { logo: "🦷", log: :Teeth },

          { logo: "🚿", log: :Shower },
          { logo: "👕", command: "do laundry" },
          { logo: "💪❌", command: "No more pullups today" },

          { logo: "🏋️‍♂️", log: "Workout {{What did you do?}}" },
          { logo: "5💪", log: "Pullups 5" },
          { logo: "#💪", log: "Pullups {{How many pullups?}}" },

          { logo: "🖋", log: "{{Log what?}}" },
          { logo: "🍕", log: "Food {{What did you eat?}}" },
          { logo: "🧃", log: "Drink {{What did you drink?}}" },
        ]
      },
      {
        logo: "🍕",
        buttons: [
          *[:tropical, :peach, :arctic].map { |flavor|
            {
              logo: "[img celsius]",
              name: flavor.to_s.titleize,
              log: "Drink Celsius #{flavor.to_s.titleize} Vibe",
            }
          },

          *[:orange, :kiwi_guava, :wild_berry].map { |flavor|
            {
              logo: "[img celsius]",
              name: flavor.to_s.titleize,
              log: "Drink Celsius #{flavor.to_s.titleize}",
            }
          },

          { logo: "🖋", log: "{{Log what?}}" },
          { logo: "🍕", log: "Food {{What did you eat?}}" },
          { logo: "🧃", log: "Drink {{What did you drink?}}" },
          { name: "Protein", log: "Drink Protein" },
          { logo: "🍍", log: "Drink Pineapple Juice" },
          { logo: "🥃", log: "Alcohol {{What did you drink?}}" },

          { logo: "[img can]", log: "Soda Mountain Dew" },
          { logo: "[img pepsi]", log: "Soda Pepsi" },
          { logo: "[img coke]", log: "Soda Coke" },
          { logo: "🥚", log: "Food Scrambled Eggs x4 on Dave's Toast x2" },
          { logo: "🍳", log: "Food Fried Eggs x3 on Dave's Toast x1" },
          { logo: "🧋", log: "Drink Chocolate Milk" },

          { logo: "🍆🥣", log: "Food Cereal Raisin Bran" },
          { logo: "🦖🥣", log: "Food Cereal Dyno Bites" },
          { logo: "🍞🥣", log: "Food Cereal Cinnamon Toast Crunch" },
          { logo: "🍯🥣", log: "Food Cereal Honey Oats" },

          { logo: "🥦🥩", log: "Food Steak and Veggies" },
          { logo: "🥦🐟", log: "Food Salmon and Veggies" },
          { logo: "🍚🥩", log: "Food Steak and Rice" },
          { logo: "🍚🐟", log: "Food Salmon and Rice" },

          { logo: "🍪🍦", log: "Treat Handel's Cookie Dough Milkshake" },
          { logo: "🥣🍦", log: "Treat Ice Cream and Caramel and Chocolate" },
          { logo: "🍓🍦", log: "Treat Costco Strawberry Sundae" },
        ]
      },
      { type: :command, },
      {
        logo: "🪶",
        page: Rails.application.routes.url_helpers.jil_prompts_path
      },
      {
        logo: "👤",
        buttons: [
          { logo: "🏠", name: "Home",        command: "Take me to Home" },
          { logo: "🔨", name: "Home Depot",  command: "Take me to Home Depot" },
          { logo: "🤸‍♀️", name: "Airsports",   command: "Take me to Airsports" },
          { logo: "🎳", name: "Bowling",     command: "Take me to Bowling" },
          { logo: "🏬", name: "Costco",      command: "Take me to Costco" },
          { logo: "🐥", name: "CarWash",     command: "Take me to CarWash" },
          { logo: "📦", name: "ParkourUtah", command: "Take me to ParkourUtah" },
          { logo: "🏌️‍♂️", name: "Lighten",     command: "Take me to Lighten" },
        ]
      },
      { type: :upcoming },
    ])
  end
end
