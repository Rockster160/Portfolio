Buddy::Tools.register(
  name:        :add_credit_button,
  summary:     "Add a credit button to THIS board: one press marks a chore done for a chosen " \
               "person (\"Dishes, by Chelsea\"). Board chat only.",
  description: <<~TXT,
    Make a credit button on the board this chat belongs to. A press marks
    `chore` done and credits `credit` with it - their pebbles, streak and
    automations - whoever actually tapped it. For chores people do for each
    other or that get marked by somebody else: "a button for Chelsea doing
    the dishes", "add a button so I can mark Ryker fed the cat".

      label  - what the button says; short. Defaults to "<chore>, <person>".
      chore  - the existing chore it completes.
      credit - a household member's first name, "me", or "whoever" for a
               button that credits whoever did it (on a board that asks who
               did each chore, it asks).
      groups - comma-separated groups it belongs to. Leave out to file it
               under this board's groups, which is what puts it on this board.
      color  - optional hex colour like "#16A34A".
  TXT
  feature:     :chores,
  board:       true,
  routinable:  false,
  args:        {
    chore:  { type: :string, required: true,  description: "Fuzzy name of the chore the button completes" },
    credit: { type: :string, required: true,  description: "Who it credits: first name, 'me', or 'whoever'" },
    label:  { type: :string, required: false, description: "What the button says; short" },
    groups: { type: :string, required: false, description: "Comma-separated groups; omit for this board's" },
    color:  { type: :string, required: false, description: "Hex colour, e.g. #16A34A" },
  },
  confirm:     ->(payload, ctx) {
    board = Buddy::BoardAdmin.board!(ctx)
    raise "no chore household on user" if ctx.user.chore_household_id.nil?

    chore = ctx.resolve_chore(payload[:chore])
    ctx.no_chore!(payload[:chore], suffix: "for the button") if chore.nil?

    whoever = payload[:credit].to_s.strip.match?(/\A(whoever|anyone|anybody|whoever did it)\z/i)
    credited = whoever ? nil : ctx.resolve_household_user(payload[:credit])
    raise "no household member called #{payload[:credit].inspect}" if !whoever && credited.nil?

    groups = GroupTaggable.normalize(payload[:groups].presence || board.named_board_groups)
    raise "#{board.display_name} watches no groups yet - set its groups first, or say which group" if groups.empty?

    color = payload[:color].to_s.strip.presence
    raise "#{color.inspect} isn't a hex colour like #16A34A" if color && !color.match?(/\A#\h{6}\z/)

    label = payload[:label].to_s.strip.presence || [chore.short_name.presence || chore.name, credited&.first_name&.upcase_first].compact.join(", ")
    {
      summary:  "Add the #{label} button?",
      resolved: { chore_id: chore.id, credit_user_id: credited&.id, tags: groups, label: label, color: color }.compact,
    }
  },
  label:       ->(payload, _ctx) {
    chore = Chore.find_by(id: payload[:chore_id])
    who = User.find_by(id: payload[:credit_user_id])&.first_name || "whoever did it"
    { title: payload[:label].to_s, sub: "#{chore&.name} → #{who} · #{Array(payload[:tags]).join(", ")}" }
  },
  level:       2,
  execute:     ->(payload, ctx) {
    Buddy::BoardAdmin.board!(ctx)
    button = ChoreCreditButton.create!(
      chore_household_id: ctx.user.chore_household_id,
      created_by_user:    ctx.user,
      chore_id:           payload[:chore_id],
      credit_user_id:     payload[:credit_user_id],
      label:              payload[:label],
      color:              payload[:color],
      tags:               Array(payload[:tags]),
    )
    ChoreBroadcaster.broadcast_changes!(ctx.user)
    {
      button_id: button.id,
      revert:    { op: "created", model: "ChoreCreditButton", id: button.id, summary: "removed the #{button.label} button" },
    }
  },
  receipt:     ->(result, _ctx) {
    "Added the #{ChoreCreditButton.find_by(id: result[:button_id])&.label || "credit"} button ✓"
  },
)
