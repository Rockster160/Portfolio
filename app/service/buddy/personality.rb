module Buddy
  # Builds the system prompt shipped to the Mac Buddy handler each turn.
  # Persona voice per theme + the marker vocabulary generated from the
  # current tool registry + the turn's context block. Rails is source
  # of truth — Mac just appends whatever we send.
  module Personality
    module_function

    PERSONA_ROOT = Rails.root.join("app/service/buddy/personalities").freeze

    RULES_APPENDIX = <<~RULES.freeze
      ---

      ## Rules of the House

      - Never say "I can't do that because I don't have permission." Either a tool below applies (use it), or you honestly don't have that capability (say so gently, in-character).
      - For anything that changes data — creating, completing, editing, logging, scheduling, removing — emit a `[[propose: <tool> arg="value" arg=value count=N]]` marker for each action. The system renders a checkbox list for the user to confirm; DO NOT act as if the change has happened until the user confirms.
      - If a proposed change repeats the same action (e.g. the user drank 5 glasses of water), prefer a single marker with `count=5` over five separate markers.
      - Show only relevant details in your prose — the user can already see today's agenda / chores in the context block; don't restate everything.
      - When the user's ask is ambiguous (which chore? which list? which occurrence?), ask a short follow-up. Don't guess destructively.
      - Never fabricate names, IDs, or times. If you don't see it in the context block, say so.
      - When the user asks to change or delete something you can see in context, use the matching edit_* / undo_* / delete_* tool. Do NOT tell them to do it themselves.
      - The current time and timezone are in the context block. Use 12-hour time in replies.
    RULES

    def for(user, tools_appendix: nil, context_block: nil)
      theme = user.buddy_theme.presence || "byte"
      persona = load_persona(theme)
      tools   = tools_appendix || Buddy::Tools.system_prompt_appendix

      parts = [persona.strip, RULES_APPENDIX.strip, tools.strip]
      parts << "## Context\n\n```json\n#{JSON.pretty_generate(context_block)}\n```" if context_block
      parts.join("\n\n---\n\n")
    end

    def load_persona(theme)
      path = PERSONA_ROOT.join("#{theme}.md")
      return default_persona(theme) unless File.exist?(path)

      File.read(path)
    end

    def default_persona(theme)
      name = theme.to_s == "moss" ? "Moss" : "Byte"
      "You are #{name}, a warm companion assistant. Be brief, kind, and specific."
    end
  end
end
