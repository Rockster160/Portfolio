module Buddy
  # The starting household vocabulary, and the code that plants it.
  #
  # It lives here rather than inside the migration that first ran it for two
  # reasons. A migration's data doesn't survive in test — `maintain_test_schema!`
  # rebuilds from schema.rb, which carries structure and nothing else — so a
  # seed only reachable from a migration is a seed no spec can check. And a new
  # household should be able to start from the same set without anyone
  # re-running a migration at it.
  #
  # Three sources:
  #
  #   1. The bullets that used to be hardcoded in Buddy::Personality's household
  #      glossary section — muti, boot, Whisper, Fae, Puppy Up/Down.
  #   2. Words that were asked for and were never in the prompt at all, most
  #      notably "the plunge", which three unrelated services had been
  #      pattern-matching by hand.
  #   3. Eve's South African substrate, lifted from her tone profile. That file
  #      teaches the companion to SPEAK these; nothing taught it to UNDERSTAND
  #      them, and those are different jobs. "Bakkie" is the sharp end: a
  #      plastic tub here, a pickup truck to everyone else, so a companion
  #      reasoning from general knowledge gets it confidently wrong.
  #
  # Only words whose meaning is opaque or actively misleading. `loo` and `torch`
  # are deliberately absent — a model already knows those, and a glossary that
  # pads itself stops getting read.
  module GlossarySeed
    module_function

    TERMS = [
      { term: "Whisper", meaning: "Their dog.", aliases: ["puppy", "pups", "the puppy", "the dog", "dog"], kind: :pet },
      {
        term:    "Fae",
        meaning: "Their cat.",
        aliases: ["kitty", "the kitty", "kitten", "the cat", "cat"],
        kind:    :pet,
        notes:   "Fae is a cat's name - never read it as a mood or an aesthetic.",
      },
      {
        term:    "Puppy Up",
        meaning: "Time to get Whisper up from a nap.",
        aliases: ["wake up Whisper", "puppy up"],
        kind:    :activity,
        notes:   "A chore record name. Use it in tool arguments; in prose say \"get Whisper up from her nap\".",
      },
      {
        term:    "Puppy Down",
        meaning: "Time to put Whisper down for a nap.",
        aliases: ["put Whisper down", "puppy down"],
        kind:    :activity,
        notes:   "A chore record name. Use it in tool arguments; in prose say \"put Whisper down for a nap\".",
      },
      {
        term:    "The plunge",
        meaning: "Horsetail Falls Trailhead in Alpine, where they go cold plunging.",
        aliases: ["plunge", "plunging", "the falls"],
        kind:    :place,
      },
      {
        term:    "Muti",
        meaning: "Medicine. \"Took my muti\" = they took their medicine.",
        aliases: ["medicine", "meds", "drugs"],
        kind:    :thing,
      },
      {
        term:    "Boot",
        meaning: "The car's trunk.",
        aliases: [],
        kind:    :thing,
        notes:   "Never footwear in this house.",
      },
      {
        term:    "Bakkie",
        meaning: "A plastic tub or food container.",
        aliases: ["bakkies"],
        kind:    :thing,
        notes:   "South African, but NOT the usual sense - it is not a pickup truck here.",
      },
      { term: "Ja", meaning: "Yes / right.", aliases: [], kind: :shorthand },
      { term: "Howzit", meaning: "Hello.", aliases: [], kind: :shorthand },
      {
        term:    "Ag shame",
        meaning: "Sympathy - \"aw, poor thing\". Never embarrassment.",
        aliases: ["shame man", "ag shame man"],
        kind:    :shorthand,
      },
      {
        term:    "Now now",
        meaning: "Shortly, in a little while. NOT immediately.",
        aliases: ["just now"],
        kind:    :shorthand,
        notes:   "The opposite of what it sounds like - treat it as \"soon\", never as \"right this second\".",
      },
      {
        term:    "Holding thumbs",
        meaning: "Fingers crossed; hoping it goes well.",
        aliases: ["hold thumbs"],
        kind:    :shorthand,
      },
      { term: "Rock up", meaning: "Show up, arrive.", aliases: ["rocked up"], kind: :shorthand },
      { term: "Schlep", meaning: "A hassle, or a long tedious trip.", aliases: ["schlepp"], kind: :shorthand },
      { term: "Eish", meaning: "Exasperation or sympathy - roughly \"oof\".", aliases: [], kind: :shorthand },
      { term: "Dankie", meaning: "Thank you.", aliases: ["baie dankie"], kind: :shorthand },
      { term: "Gemors", meaning: "A mess.", aliases: [], kind: :shorthand },
      { term: "Frot", meaning: "Rotten, gone off.", aliases: ["vrot"], kind: :shorthand },
      {
        term:    "Dailies",
        meaning: "The basic chores meant to be done every day - their pending-today rotation.",
        aliases: ["my dailies"],
        kind:    :shorthand,
      },
      {
        term:    "Quiet time",
        meaning: "Whisper's quiet mode - the window where the dog is settled and nothing should make noise.",
        aliases: ["quiet mode", "quiet hours"],
        kind:    :activity,
        notes:   "Set it with the \"Whisper Quiet For\" function, never a timer. \"Quiet time for an hour\" " \
                 "means quiet until an hour from now - a countdown named \"quiet time\" does nothing at all.",
      },

      # Devices are the one kind where `meaning` is load-bearing rather than
      # explanatory: Buddy::DeviceStates reads it as the name the sensor
      # actually reports under in the Home Assistant cache. Nobody says "Doggy
      # Sensor" out loud, so without these a question about the doggy door
      # reaches nothing and gets answered "I can't check that from here" while
      # the state sits in the cache.
      {
        term:    "The doggy door",
        meaning: "Doggy Sensor",
        aliases: ["doggy door", "dog door", "puppy door"],
        kind:    :device,
      },
      {
        term:    "The kennel",
        meaning: "Kennel Sensor",
        aliases: ["kennel", "kennel door", "crate"],
        kind:    :device,
      },
      {
        term:    "The laundry gate",
        meaning: "Laundry Gate",
        aliases: ["laundry gate", "the gate"],
        kind:    :device,
      },
      {
        term:    "The front door",
        meaning: "Doorbell",
        aliases: ["front door", "doorbell", "the door", "entry"],
        kind:    :device,
        notes:   "One sensor covers all of these - the doorbell camera at the front.",
      },
      { term: "The driveway", meaning: "Driveway", aliases: ["driveway"], kind: :device },
      { term: "The backyard", meaning: "Backyard", aliases: ["backyard", "back yard"], kind: :device },
      {
        term:    "The bins",
        meaning: "Bins",
        aliases: ["bins", "garbage cans", "trash cans"],
        kind:    :device,
      },
      { term: "The printer", meaning: "octoprint", aliases: ["printer", "3d printer"], kind: :device },
    ].freeze

    # Idempotent: a term the household already has is left exactly as it is,
    # since anything they edited by hand beats anything shipped here.
    def plant!(household)
      return 0 if household.nil?

      existing = HouseholdGlossaryTerm.where(chore_household_id: household.id).pluck(:term).map(&:downcase)
      TERMS.count { |seed|
        next false if existing.include?(seed[:term].downcase)

        HouseholdGlossaryTerm.create!(seed.merge(chore_household_id: household.id))
        true
      }
    end
  end
end
