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
          { name: "Vitamins", command: "log Vitamins" },
          { name: "D-AmphXR 20mg", command: "log D-AmphetamineXR 20mg" },
          { name: "D-Amph 20mg", command: "log D-Amphetamine 20mg" },
          { name: "Pristiq 25mg", command: "log Pristiq 25mg" },
          { name: "AdderallXR 15mg", command: "log AdderallXR 15mg" },
          { name: "AdderallXR 20mg", command: "log AdderallXR 20mg" },
          { name: "Buspirone 20mg", command: "log Buspirone 20mg" },
          { name: "Relaxium 1", command: "log Relaxium 1" },
          { name: "Relaxium 2", command: "log Relaxium 2" },
          { name: "NQ", command: "log NQ" },
          { name: "NQ Half", command: "log NQ Half" },
          { name: "Methyl 10mg", command: "log Methylphenidate 10mg" },
          { name: "Methyl 20mg", command: "log Methylphenidate 20mg" },
          { name: "Escital 20mg", command: "log Escitalopram 20mg" },
          { name: "X", command: "log X" },
          { name: "Z", command: "log Z {{}}" },
        ]
      },
      {
        logo: "[ico fa-paper_plane width: 32px;]",
        buttons: [
          { logo: "🔄", page: ".reload" },
          { logo: "💧", command: "log Water" },
          { logo: "🦷", command: "log Teeth" },

          { logo: "🚿", command: "log Shower" },
          { logo: "👕", command: "do laundry" },
          { logo: "💪❌", command: "No more pullups today" },

          { logo: "🏋️‍♂️", command: "log Workout {{What did you do?}}" },
          { logo: "💪", name: "5", command: "log Pullups 5" },
          { logo: "💪", name: "#", command: "log Pullups {{How many pullups?}}" },

          { logo: "🖋", command: "log {{Log what?}}" },
          { logo: "🍕", command: "log Food {{What did you eat?}}" },
          { logo: "🧃", command: "log Drink {{What did you drink?}}" },
        ]
      },
      {
        logo: "🍕",
        buttons: [
          *[:tropical, :peach, :arctic].map { |flavor|
            {
              logo: "[img celsius]",
              name: flavor.to_s.titleize,
              command: "log Drink Celsius #{flavor.to_s.titleize} Vibe",
            }
          },

          *[:orange, :kiwi_guava, :wild_berry].map { |flavor|
            {
              logo: "[img celsius]",
              name: flavor.to_s.titleize,
              command: "log Drink Celsius #{flavor.to_s.titleize}",
            }
          },

          { logo: "🖋", command: "log {{Log what?}}" },
          { logo: "🍕", command: "log Food {{What did you eat?}}" },
          { logo: "🧃", command: "log Drink {{What did you drink?}}" },
          { name: "Protein", command: "log Drink Protein" },
          { logo: "🍍", command: "log Drink Pineapple Juice" },
          { logo: "🥃", command: "log Alcohol {{What did you drink?}}" },

          { logo: "[img can]", command: "log Soda Mountain Dew" },
          { logo: "[img pepsi]", command: "log Soda Pepsi" },
          { logo: "[img coke]", command: "log Soda Coke" },
          { logo: "🥚", command: "log Food Scrambled Eggs x4 on Dave's Toast x2" },
          { logo: "🍳", command: "log Food Fried Eggs x3 on Dave's Toast x1" },
          { logo: "🧋", command: "log Drink Chocolate Milk" },

          { logo: "🍆🥣", command: "log Food Cereal Raisin Bran" },
          { logo: "🦖🥣", command: "log Food Cereal Dyno Bites" },
          { logo: "🍞🥣", command: "log Food Cereal Cinnamon Toast Crunch" },
          { logo: "🍯🥣", command: "log Food Cereal Honey Oats" },

          { logo: "🥦🥩", command: "log Food Steak and Veggies" },
          { logo: "🥦🐟", command: "log Food Salmon and Veggies" },
          { logo: "🍚🥩", command: "log Food Steak and Rice" },
          { logo: "🍚🐟", command: "log Food Salmon and Rice" },

          { logo: "🍪🍦", command: "log Treat Handel's Cookie Dough Milkshake" },
          { logo: "🥣🍦", command: "log Treat Ice Cream and Caramel and Chocolate" },
          { logo: "🍓🍦", command: "log Treat Costco Strawberry Sundae" },
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
          { logo: "🏠", name: "Home",       command: "Take me to Home" },
          { logo: "🔨", name: "Home Depot", command: "Take me to Home Depot" },
          { logo: "🤸‍♀️", name: "Airsports",  command: "Take me to Airsports" },
          { logo: "🎳", name: "Bowling",    command: "Take me to Bowling" },
          { logo: "🏬", name: "Costco",     command: "Take me to Costco" },
          { logo: "🐥", name: "CarWash",    command: "Take me to CarWash" },
          { logo: "📦", name: "PKUT",       command: "Take me to ParkourUtah" },
          { logo: "🏌️‍♂️", name: "Lighten",    command: "Take me to Lighten" },
        ]
      },
      { type: :upcoming },
    ])
  end
end
