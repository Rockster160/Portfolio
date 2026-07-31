Buddy::Tools.register(
  name:        :mac_command,
  description: <<~TXT,
    Do something on the Mac at the desk. This is the machine itself - its
    screens, its state - not the house automations, which live in
    `jil_triggers` / `jil_functions`.

    Runs immediately. Only the commands listed here exist; if the person asks
    for something the Mac could obviously do but that isn't on the list, say it
    isn't wired up rather than stretching a near-miss. The Mac may also be
    asleep or unreachable, in which case you'll be told so and should pass that
    on plainly instead of claiming it worked.

    #{ByteLocal::MAC_COMMANDS.map { |name, purpose| "- `#{name}`: #{purpose}" }.join("\n")}
  TXT
  feature:     :mac,
  args:        {
    command: {
      type:        :enum,
      required:    true,
      values:      ByteLocal::MAC_COMMANDS.keys,
      description: "Which Mac command to run",
    },
  },
  # Level 1: same shape as the house commands. "Kill the monitors" should just
  # happen and leave a receipt, not hand back a checkbox to tap.
  level:       1,
  confirm:     ->(payload, _ctx) {
    { summary: "Run **#{payload[:command]}** on the Mac?", resolved: {} }
  },
  label:       ->(payload, _ctx) { { title: payload[:command].to_s.tr("_", " "), sub: "on the Mac" } },
  execute:     ->(payload, _ctx) { ByteLocal.run_command(payload[:command]) },
  # Most of these say nothing (pmset just does it), so the chip is normally just
  # the name. When a command DOES answer, that answer is the entire point of
  # having run it, so it goes on the chip rather than being dropped.
  receipt:     ->(result, ctx) {
    name = ctx.proposal&.dig("payload", "command").to_s.tr("_", " ").presence || "That"
    said = result.is_a?(Hash) ? result[:output].to_s.lines.first.to_s.strip : ""
    [name.capitalize, said.presence&.truncate(120)].compact.join(" - ") + " ✓"
  },
)
