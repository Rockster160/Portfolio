module RecordLinks
  # The pairings as they existed in Jil, moved across — minus the two rules that
  # ran uphill.
  #
  # Source of truth was three function tasks holding Ruby-ish Hash literals:
  # 361 "Chore Event Map", 364 "Chore Event Map (Ambiguous)", 381 "List Chore
  # Item Map", plus two hand-written agenda tasks (370, 374). Which listener
  # tasks existed was the only place direction was ever expressed:
  #
  #   362 event -> chore        kept
  #   365/366 ambiguous         kept, as ask_who
  #   370/374 event -> agenda   kept
  #   383 chore done -> item    kept
  #   416 chore due -> item     kept
  #   363 chore -> event        DROPPED, runs uphill
  #   382 item -> chore due     DROPPED, runs uphill
  #
  # Dropping 382 is the one with a behavioural consequence, so it doesn't just
  # vanish: the five cron and button tasks that used to add those items now mark
  # the chore due instead, and 416 pushes the item back down. Same outcome, one
  # arrow. See lib/scripts/rewrite_mark_due_tasks.rb.
  #
  # One simplification worth naming. Eight Fae pairings sat in BOTH the plain
  # map and the ambiguous one, so an event fired 362 (make a completion) and 365
  # (raise a prompt) at once, and 366 then DESTROYED the event to undo the first
  # before completing for whoever was named. Net effect: one completion,
  # attributed correctly, reached the long way round. One row per pairing means
  # those carry `ask_who` alone and land in the same place without the
  # demolition.
  module Seed
    module_function

    # chore <-> event, expressed event-first because that's the direction it
    # runs. `notes` is the event's notes constraint.
    #
    # `match` is `exactly` unless stated. The two `contains` entries are the
    # ones that were fragile: a medication is logged with its dosage, and the
    # Cymbalta string carries a typo ("Hydrochlride") that any re-typing would
    # miss.
    EVENT_CHORE = [
      { event: "Wordle",         chore: "Wordle" },
      { event: "Teeth",          chore: "Teeth" },
      { event: "Shower",         chore: "Shower" },
      { event: "AnimalCrossing", chore: "ACNH Chores" },
      { event: "D-Amphetamine",  chore: "Focus", name_match: :starts_with },
      { event: "Chore",          chore: "Go get mail",         notes: "Mail" },
      { event: "Chore",          chore: "Take trash cans out", notes: "TrashCansOut" },
      { event: "Game",           chore: "Play Slime Colony",   notes: "Slime Colony" },
      { event: "M",              chore: "Cymbalta", notes: "Duloxetine", scope_match: :contains },
      # Ambiguous: more than one person in the house does these.
      { event: "Fae", chore: "Refill Fae Food",          notes: "Food",          ask: true },
      { event: "Fae", chore: "Kitty Litter",             notes: "Litter",        ask: true },
      { event: "Fae", chore: "Take out Kitty Genie Bag", notes: "Genie",         ask: true },
      { event: "Fae", chore: "Fae Probiotic",            notes: "Probiotic",     ask: true },
      { event: "Fae", chore: "Deep Clean Cat Area",      notes: "VacuumLaundry", ask: true },
      { event: "Fae", chore: "Vacuum Litter Mat",        notes: "VacuumMat",     ask: true },
      { event: "Fae", chore: "Fae Wipe",                 notes: "Wipe",          ask: true },
      { event: "Fae", chore: "Fae Muti", notes: "Metronidazole", ask: true, scope_match: :contains },
      { event: "Laundry", chore: "Laundry", ask: true },
      { event: "Whisper", chore: "Whisper training", notes: "Training", ask: true },
      { event: "Whisper", chore: "Puppy Up",         notes: "Up",       ask: true },
      { event: "Whisper", chore: "Puppy Down",       notes: "Down",     ask: true },
      { event: "Whisper", chore: "Puppy Down",       notes: "Nap",      ask: true },
      { event: "Whisper", chore: "Puppy Down",       notes: "Sleep",    ask: true },
      { event: "Whisper", chore: "Puppy Fed",        notes: "Fed",      ask: true },
      { event: "Whisper", chore: "Bathe puppy",      notes: "Bath",     ask: true },
    ].freeze

    # chore -> list item. Marking the chore due puts the item on; completing it
    # takes the item off.
    CHORE_ITEM = [
      ["Check Softener Salt",      "Check Salt",               "Chores"],
      ["Replace Air Filter",       "Change Air Filter",        "Chores"],
      ["Go get mail",              "Get the Mail",             "Chores"],
      ["Pickup RX",                "Pickup RX",                "Chores"],
      ["Bring trash cans in",      "Bring in garbage cans",    "Todo"],
      ["Take trash cans out",      "Take Trash Out",           "Todo"],
      ["Restock Soda",             "Refill Drinks",            "Todo"],
      ["Restock Protein",          "Refill Protein Drinks",    "Todo"],
      ["Cymbalta",                 "Cymbalta",                 "Todo"],
      ["Refill Fae Food",          "Refill Fae Food",          "Fae Chores"],
      ["Kitty Litter",             "Kitty Litter",             "Fae Chores"],
      ["Take out Kitty Genie Bag", "Take out Kitty Genie Bag", "Fae Chores"],
      ["Fae Probiotic",            "Fae Probiotic",            "Fae Chores"],
      ["Deep Clean Cat Area",      "Deep Clean Cat Area",      "Fae Chores"],
      ["Vacuum Litter Mat",        "Vacuum Litter Mat",        "Fae Chores"],
      ["Fae Wipe",                 "Fae Wipe",                 "Fae Chores"],
      ["Fae Muti",                 "Fae Muti",                 "Fae Chores"],
    ].freeze

    # event -> agenda. "overdue" reproduces task 370, which swept overdue Shower
    # items as well as today's; 374 did today only. The medication carries the
    # same loose match as its chore pairing, for the same reason: it's logged
    # with a dosage, and the formulation itself gets re-typed ("D-AmphetamineXR").
    EVENT_AGENDA = [
      { event: "Shower",        agenda: "Shower", scope: "overdue" },
      { event: "D-Amphetamine", agenda: "Focus",  name_match: :starts_with },
    ].freeze

    # Idempotent. A pairing that already exists keeps whatever it has now, since
    # anything edited by hand beats anything shipped here.
    def plant!(user)
      return 0 if user.nil?

      rows = EVENT_CHORE.map { |e|
        {
          source_kind:        :event,
          source_name:        e[:event],
          source_scope:       e[:notes],
          source_name_match:  e[:name_match] || :exactly,
          source_scope_match: e[:scope_match] || :exactly,
          target_kind:        :chore,
          target_name:        e[:chore],
          ask_who:            !!e[:ask],
        }
      }
      rows += CHORE_ITEM.map { |chore, item, list|
        {
          source_kind:  :chore,
          source_name:  chore,
          target_kind:  :list_item,
          target_name:  item,
          target_scope: list,
        }
      }
      rows += EVENT_AGENDA.map { |e|
        {
          source_kind:       :event,
          source_name:       e[:event],
          source_name_match: e[:name_match] || :exactly,
          target_kind:       :agenda,
          target_name:       e[:agenda],
          target_scope:      e[:scope],
        }
      }

      rows.count { |attrs| create_unless_present(user, attrs) }
    end

    def create_unless_present(user, attrs)
      scope = RecordLink.where(
        user_id:     user.id,
        source_kind: RecordLink::KINDS.fetch(attrs[:source_kind]),
        target_kind: RecordLink::KINDS.fetch(attrs[:target_kind]),
      )
      scope = scope.where(
        "LOWER(source_name) = ? AND LOWER(target_name) = ?",
        attrs[:source_name].downcase, attrs[:target_name].downcase
      )
      scope = (
        if attrs[:source_scope].nil?
          scope.where(source_scope: nil)
        else
          scope.where("LOWER(source_scope) = ?", attrs[:source_scope].downcase)
        end
      )
      return false if scope.exists?

      RecordLink.create!(attrs.merge(user: user, note: "migrated from Jil"))
      true
    end
  end
end
