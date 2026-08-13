# The single source of truth for the spending-category vocabulary AND for which
# merchant belongs to which category.
#
# It used to live in four places that had to be edited together — this module,
# Jil task 453's merchant rules, the `choices` on the categorization Prompt,
# and CustomChart 4's color map. Adding a category meant remembering all four,
# and `Extra Expense` is in the data exactly once because someone did not.
#
# Now Rails owns it and everything else derives: Jil reads it through
# `TransactionCategory.all()` / `.colors()` / `.match()` (see
# Jil::Methods::TransactionCategory) so the tasks no longer carry a copy, and
# the chart's color map is generated from `chart_color_config` rather than
# maintained alongside it.
# rubocop:disable Metrics/ModuleLength -- almost all of it is MERCHANT_RULES, a
# 288-entry data table with one merchant per line. Splitting it out to satisfy a
# length budget would put the vocabulary in one file and the rules in another,
# which is the several-places-to-edit problem this module was made to end.
module TransactionCategory
  # ONE hash: the category and the color it is drawn in. The list and the
  # palette are the same thing, so keeping them as separate constants meant
  # writing all 22 names twice and having no way to notice when they drifted.
  #
  # Alphabetical, and `ALL` re-sorts rather than trusting this to stay that
  # way — adding one in the wrong place should not reorder the UI.
  CATEGORIES = {
    alcohol:        "#CBB994",
    car:            "#8A6D3B",
    "card payment": "#6E7681",
    "eat out":      "#D95926",
    fun:            "#F5D67B",
    groceries:      "#3987E5",
    health:         "#59C26A",
    hobby:          "#45B6D4",
    home:           "#C98500",
    hosting:        "#A8E6CF",
    insurance:      "#DCA3B1",
    medical:        "#1DC91D",
    mortgage:       "#E66767",
    other:          "#AEB6C2",
    "pay check":    "#008300",
    people:         "#14C8B4",
    pets:           "#B07CC6",
    shopping:       "#D55181",
    subscriptions:  "#9085E9",
    taxes:          "#C91DC9",
    travel:         "#9EC91D",
    utilities:      "#199E70",
  }.freeze

  ALL = CATEGORIES.keys.sort_by(&:to_s).freeze
  DEFAULT = :other

  # Which merchant means which category. Ported verbatim from Jil task 453,
  # which owned it until 2026-08-12 and is now deleted — a copy in Jil and a
  # copy here is the exact problem this module exists to end.
  #
  # ORDER IS LOAD-BEARING. The first rule that matches wins, so the specific
  # must precede the general: "AMAZON WEB" is hosting and has to be tested
  # before "AMAZON" claims it for shopping, and "PRIME PMTS"/"PRIME VIDEO" are
  # subscriptions before "AMZN" sees them. Re-sorting this hash silently
  # recategorizes spending.
  #
  # Fragments rather than one long pattern per category, purely so a merchant
  # can be added as a single word on its own line. They are joined with `|`
  # into exactly the alternation Jil held as one string.
  #
  # Note the anchored ones (`\A...\z`): "JPMORGAN CHASE" alone is the mortgage,
  # but as a substring it would also swallow every other Chase line item.
  MERCHANT_RULES = {
    mortgage:       ["\\AJPMORGAN CHASE\\z"],
    "pay check":    ["direct deposit", "check deposit"],
    "card payment": ["\\ACHASE CREDIT CRD\\z", "\\APayment\\z"],
    insurance:      [
      "PROG DIRECT",
      "BEAR RIVER MUT",
      "INSUR",
      "GEICO",
      "STATE FARM",
      "ALLSTATE",
      "TRAVELERS",
      "CLAIM SOLUTI",
    ],
    taxes:          ["\\AIRS\\z", "INTUIT", "UDOT RUC", "TREASURY", "UTAH. MVED"],
    hosting:        ["DIGITALOCEAN", "AMAZON WEB", "TWILIO", "NAME.?CHEAP", "GITHUB"],
    subscriptions:  [
      "NETFLIX",
      "DISNEY",
      "SPOTIFY",
      "CRUNCHYROLL",
      "OPENAI",
      "CLAUDE.AI",
      "ANTHROPIC",
      "KINDLE",
      "PRIME PMTS",
      "PRIME VIDEO",
      "HULU",
      "PATREON",
      "DOLLARSHAVECLUB",
    ],
    groceries:      [
      "COSTCO",
      "HARMONS",
      "TRADER JOE",
      "SMITHS",
      "TARGET",
      "WAL.?MART",
      "WM SUPERCENTER",
      "SPROUTS",
      "WINCO",
      "QFC",
      "STOKES",
      "FRESH MARKET",
      "CHINATOWN SUPERMARK",
      "OCEAN MART",
      "PIRATE O",
    ],
    alcohol:        [
      "LIQUOR",
      "BREWING",
      "BREWERY",
      "BREWI",
      "WHISKEY",
      "SALOON",
      "HELPER BEER",
      "LUCKY 13",
      "STATION BAR",
    ],
    "eat out":      [
      "GOLD FISH",
      "LOS TORITOS",
      "ICHI JAPAN",
      "TORO RAMEN",
      "TEXAS ROADHOUSE",
      "IN.N.OUT",
      "CAFE RIO",
      "CHICK.FIL.A",
      "KNEADERS",
      "PEPPER LUNCH",
      "GURAS",
      "ROXBERRY",
      "TROPICAL SMOOTHIE",
      "QUENCH",
      "SLACKWATER",
      "SWIG",
      "CHIPOTLE",
      "PANDA EXPRESS",
      "MCDONALD",
      "WENDY",
      "SUBWAY",
      "STARBUCKS",
      "DOMINO",
      "PIZZA",
      "SUSHI",
      "RAMEN",
      "BAKERY",
      "GRILL",
      "TACO",
      "BURGER",
      "CAFE",
      "DINER",
      "BISTRO",
      "RESTAURANT",
      "BERTOS",
      "BETOS",
      "DOORDASH",
      "GRUBHUB",
      "UBER . EATS",
      "DUTCH BROS",
      "BEANS .{0,6}BREWS",
      "HANDELS",
      "HUMAN BEAN",
      "THB ",
      "HAMACHI",
      "OLIVE GARDEN",
      "FIVE GUYS",
      "KFC",
      "IHOP",
      "SBARRO",
      "POTBELLY",
      "DAIRY QUEEN",
      "FREDDYS",
      "SHAKE SHACK",
      "WAFFLE LOVE",
      "NEKTER",
      "ACAI",
      "THIRST DRINKS",
      "SUPER CHIX",
      "KIN KAO",
      "PHO ",
      "RED FORT",
      "SAFFRON VALLEY",
      "UMAMI",
      "VIETOPIA",
      "ASIAN CITY",
      "TERIYAKI",
      "NOODLE",
      "KABOB",
      "KIPOS",
      "MARMALADE",
      "LA FOUNTAIN",
      "JIMS -",
      "SKINNYFATS",
      "THE PIE",
      "CRAB POT",
      "HOUSTON.S HOT",
      "COFFEE",
      "CANNOLI",
      "JUICE",
    ],
    utilities:      [
      "ROCKYMTN",
      "DOMINION ENERGY",
      "HERRIMAN CITY",
      "JORDAN BASIN",
      "T.MOBILE",
      "LUMEN",
      "CENTURYLINK",
      "XFINITY",
      "COMCAST",
      "WASATCH FRONT",
      "QUANTUM FIBER",
      "ENBRIDGE",
      "RIVERTON CITY",
      "TRANS JORDAN",
      "SOUTH VALLEY SEW",
    ],
    home:           [
      "HOME DEPOT",
      "LOWE",
      "IKEA",
      "RC WILLEY",
      "ACE HARDWARE",
      "MENARDS",
      "SMARTWINGS",
      "CRATE AND BARREL",
      "ASHLEYFURNITURE",
      "AT HOME STORE",
      "HOMEGOODS",
      "RUGGABLE",
      "MILKHOUSE CANDLE",
      "PEST CONTR",
      "VIVINT",
      "INOVELLI",
      "DR. VOLTS",
    ],
    car:            [
      "TESLA",
      "QUICKQUACK",
      "MCNEILS",
      "DMV",
      "NISSAN",
      "JIFFY LUBE",
      "CHEVRON",
      "MAVERIK",
      "SINCLAIR",
      "AUTOZONE",
      "LES SCHWAB",
      "LYFT",
      "UBER .TRIP",
      "UBR.",
      "BIG O",
      "O.REILLY",
      "PARKING",
      "PARKWHIZ",
      "CYCLE GEAR",
    ],
    pets:           [
      "PETSMART",
      "PETCO",
      "CHEWY",
      "VETERI",
      "GENTLE VET",
      "ROVER.COM",
      "ANIMAL HOSPITAL",
    ],
    health:         ["SERENITY MENTAL", "MOUNTAIN YOGA", "YOGA BARN", "HAPPINESS WITHIN"],
    medical:        [
      "PHARMACY",
      "WALGREENS",
      "CVS",
      "DENTAL",
      "DDS",
      "ORTHODONT",
      "CLINIC",
      "MEDICAL",
      "HOSPITAL",
      "OPTOMETRY",
      "RETINA",
      "VITREOUS",
      "INTERMOUNTAIN HE",
      "ORTHOFEET",
    ],
    hobby:          [
      "GAME HAVEN",
      "GALAXYOFGAMES",
      "HOBBY LOBBY",
      "MICHAELS",
      "JOANN",
      "GAMESTOP",
      "THIEVES GUILD",
      "NINTENDO",
      "STEAM",
      "BOARDGAMES",
      "OASIS GAMES",
      "RECORD SHO",
      "LEGENDARIUM",
    ],
    travel:         [
      "AIRBNB",
      "RESORT",
      "LODGE",
      "HOTEL",
      "MARRIOTT",
      "HILTON",
      "DELTA AIR",
      "EXPEDIA",
      "FRONTIER RESERV",
      "WSFERRIES",
      "CITY PASS",
      "HUDSONNEWS",
      "STRAWBERRY BAY",
    ],
    fun:            [
      "MOMENTUM",
      "CINEMA",
      "THEATRE",
      "THEATER",
      "MEGAPLEX",
      "TRAMPOLINE",
      "BOWLING",
      "TOPGOLF",
      "FAT CATS",
      "FIESTA FUN",
      "MUSEUM",
      "NHMU",
      "DLR ",
      "DELTA CENTER",
      "THEAT",
      "FANDANGO",
      "GARDNER VILLAGE",
      "STATE PARKS",
      "HUNT.FISH",
    ],
    people:         ["\\AVENMO\\z", "ZELLE", "CASH APP", "PAYPAL"],
    shopping:       [
      "AMAZON",
      "AMZN",
      "T.J. MAXX",
      "TJ MAXX",
      "ROSS STORES",
      "KOHL",
      "BEST ?BUY",
      "WAYFAIR",
      "ETSY",
      "EBAY",
      "SCHEELS",
      "REI #",
      "SIERRA #",
      "AMERICAN EAGLE",
      "FAMOUS FOOTWEAR",
      "BARNES",
      "MICROSOFT",
      "FABLETICS",
      "OWALA",
      "SPORTSMAN",
      "SPORTING GOODS",
      "UPS STORE",
      "JEWELR",
    ],
  }.freeze

  # Compiled once. IGNORECASE and MULTILINE because that is exactly what Jil's
  # `to_regex` applied — without IGNORECASE the lowercase "direct deposit" rule
  # would stop matching, and the port would silently lose pay checks.
  MERCHANT_PATTERNS = MERCHANT_RULES.transform_values { |fragments|
    ::Regexp.new(fragments.join("|"), ::Regexp::IGNORECASE | ::Regexp::MULTILINE)
  }.freeze

  # What was BOUGHT, for merchants that sell everything. The merchant rules put
  # every Amazon charge under `shopping`, which is true of the shop and useless
  # about the purchase.
  #
  # DELIBERATELY CONSERVATIVE, because the existing hand-labelled data says so.
  # "Acrylic Markers", "Trash Baggies", "Shoulder bag", "Pillow", "AirTag
  # Batteries" and even "Automotive item" were all filed under `shopping` by
  # hand. General goods belong there; only a clear signal should pull one out.
  # Anything unmatched keeps whatever the merchant rules decided.
  #
  # `home` is house fixtures and systems — the hand-labelled examples are
  # "Light Sockets", "Thermostats", "Smart Thermometers", Home Depot, Vivint —
  # NOT housewares. `fun` is gaming, from "Controller Shell" and "Red Keyb
  # Keys". `hobby` is tabletop, craft and tinkering, from Game Haven, Hobby
  # Lobby and Steam.
  #
  # Ordered like MERCHANT_RULES: first match wins, specific before general.
  ITEM_RULES = {
    pets:      [
      "\\bdog\\b",
      "\\bcat\\b",
      "\\bcats\\b",
      "\\bpet\\b",
      "\\bpets\\b",
      "\\bpuppy\\b",
      "\\bkitten\\b",
      "\\bfeline\\b",
      "\\bcanine\\b",
      "litter box",
      "cat litter",
      "pee pads",
      "\\bleash\\b",
      "pet carrier",
    ],
    medical:   [
      "pedialyte",
      "pepto",
      "ibuprofen",
      "acetaminophen",
      "\\bgauze\\b",
      "first aid",
      "\\bbandage",
      "antacid",
      "cough drop",
      "\\bantibiotic",
      "blood pressure monitor",
      "pill organizer",
    ],
    groceries: [
      # Consumables. `coffee` on its own would claim a coffee MUG, so the
      # grounds and the beans are named instead.
      "celsius",
      "hint water",
      "\\bpropel\\b",
      "gatorade",
      "sprite",
      "coca.cola",
      "\\bpopcorn\\b",
      "protein shake",
      "protein powder",
      "\\bsyrup\\b",
      "grenadine",
      "olive oil",
      "\\bseasoning\\b",
      "\\bsnack",
      "granola",
      "\\bcereal\\b",
      "\\bcandy\\b",
      "\\bchocolate\\b",
      "beef jerky",
      "coffee beans",
      "ground coffee",
      "k.cups?\\b",
      "\\btea bags\\b",
      "electrolyte",
      "drink mix",
      "sparkling water",
      "energy drink",
    ],
    hobby:     [
      "\\bdice\\b",
      "\\bdnd\\b",
      "dungeons . dragons",
      "\\btcg\\b",
      "card sleeves",
      "board game",
      "\\bjigsaw\\b",
      "\\bpuzzle\\b",
      "3d printer",
      "printer filament",
      "\\bpla\\b filament",
      "\\bresin\\b",
      "development board",
      "\\barduino\\b",
      "raspberry pi",
      "soldering",
      "\\bminiatures?\\b",
      "lorcana",
      "magic the gathering",
      "\\bwarhammer\\b",
    ],
    fun:       [
      "nintendo switch",
      "\\bjoy.?con",
      "\\bjoystick\\b",
      "game controller",
      "\\bxbox\\b",
      "playstation",
      "\\bps5\\b",
      "gaming mouse",
      "gaming keyboard",
      "\\bamiibo\\b",
    ],
    car:       [
      "\\btesla\\b",
      "model [3y]\\b",
      "\\bwindshield\\b",
      "\\bwiper blade",
      "\\btire\\b",
      "\\btires\\b",
      "motor oil",
      "\\bautomotive\\b",
      "license plate",
      "car charger",
      "\\bobd2?\\b",
    ],
    home:      [
      "light bulb",
      "\\bbulbs?\\b",
      "light socket",
      "\\bthermostat",
      "\\bfaucet\\b",
      "\\bcaulk\\b",
      "weather ?strip",
      "smoke detector",
      "\\bdoorbell\\b",
      "outlet cover",
      "\\bdrywall\\b",
      "\\bgrout\\b",
      "\\bshowerhead\\b",
      "air filter",
      "furnace filter",
      "\\bcircuit breaker",
    ],
    travel:    [
      "\\bluggage\\b",
      "\\bsuitcase\\b",
      "packing cubes",
      "travel pillow",
      "passport holder",
      "\\bcarry.on\\b",
    ],
  }.freeze

  ITEM_PATTERNS = ITEM_RULES.transform_values { |fragments|
    ::Regexp.new(fragments.join("|"), ::Regexp::IGNORECASE | ::Regexp::MULTILINE)
  }.freeze
  # Strays render in a neutral gray rather than borrowing a real category's
  # color, so "this is not a real category" is visible on the chart.
  FALLBACK_COLOR = "#475569".freeze

  class << self
    # Stored lowercase ("eat out"); rendered titleized ("Eat Out"). The select
    # submits the stored form so nothing round-trips into a new spelling.
    def options
      ALL.map { |category| [category.to_s.titleize, category.to_s] }
    end

    def label(category)
      category.to_s.titleize
    end

    def color(category)
      CATEGORIES[category.to_s.to_sym] || FALLBACK_COLOR
    end

    def valid?(category)
      CATEGORIES.key?(category.to_s.to_sym)
    end

    # Nil rather than DEFAULT on an unknown value: silently rewriting an
    # unrecognized category to "other" would erase the fact that something
    # wrote a category nothing knows about. `Extra Expense` is in the data
    # exactly once for that reason.
    def cast(category)
      ALL.detect { |known| known.to_s == category.to_s }
    end

    # Which category a merchant name belongs to, or nil when no rule claims it.
    #
    # NIL, not DEFAULT. Jil returned "other" for anything unmatched, which is
    # right when a human is about to see the answer in a prompt they can
    # correct — and wrong when it is applied to thousands of rows unattended,
    # where it would bury every merchant nobody has written a rule for under a
    # category that looks deliberate. Callers that want the old behaviour say
    # so; see Jil::Methods::TransactionCategory#match.
    def for_merchant(merchant)
      text = merchant.to_s
      return nil if text.blank?

      # `detect` on an ordered hash — first match wins, which is the whole
      # contract MERCHANT_RULES' ordering encodes.
      MERCHANT_PATTERNS.detect { |_category, pattern| pattern.match?(text) }&.first
    end

    # What a purchase was, from the item description — for merchants that sell
    # everything and whose own name says nothing useful.
    #
    # Nil when no rule is confident, and nil MEANS "leave it where the merchant
    # put it". That is the whole safety property: an unrecognized item stays
    # `shopping` rather than being pulled somewhere worse.
    def for_item(text)
      body = text.to_s
      return nil if body.blank?

      ITEM_PATTERNS.detect { |_category, pattern| pattern.match?(body) }&.first
    end

    # The color map in the exact shape CustomChart 4's config expects, so the
    # chart is GENERATED from this rather than kept in step with it by hand.
    def chart_color_config
      ALL.map { |category| "#{category} = #{CATEGORIES[category]}" }.join("\n")
    end

    # Categories present in the data but outside the vocabulary. These render
    # uncolored on the chart and are what the banking page's cleanup surface
    # exists to catch.
    #
    # Reads bank_transactions, which is where a category is stored now. The
    # events it used to read still carry a mirrored copy, but only for the
    # fraction of transactions an alert email ever covered.
    def unknown_in_use
      used = ::BankTransaction.distinct.pluck(:category)
      used.compact_blank.reject { |category| valid?(category) }
    end
  end
end
# rubocop:enable Metrics/ModuleLength
