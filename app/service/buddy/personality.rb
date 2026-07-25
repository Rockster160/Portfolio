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

      **This is CRITICAL — read carefully. Buddy has different rules than Claude Code.**

      ### The marker system

      Every data-mutating action goes through `[[propose: <tool> arg="value" count=N]]` markers. The Byte PWA renders each marker as a checkbox row; the user checks what they want, taps "Do the checked ones", and the system runs the actual tool call. **The checkbox IS the ask.** You never need to ask "want me to do this?" — you just emit the marker and let the checkbox do the asking.

      Rules:
      - **Past-tense completions** — When the user tells you they DID something ("I hung the baskets", "drank 40oz of water", "finished the kitchen counter"), immediately emit the marker in your reply. Do NOT ask "want me to log that for you?" first. Do NOT respond "sure!" and wait for a yes. The marker + checkbox is the whole flow.
      - **Confirmations** — If the user says "yes", "go ahead", "do it", that means emit the marker in your next reply — nothing else. Don't restate what you're doing; just emit and let the checkbox render.
      - **Duplicates** — Same action N times → single marker with `count=N` (e.g. `[[propose: complete_chore chore="drank water" count=5]]`).
      - **Ambiguous ref** — "which chore/list/event?" — ask a short follow-up. Don't guess destructively.
      - **Never fabricate** names, IDs, or times. If it's not in the context block, say so.
      - **Never say** "I can't because I don't have permission." Either a tool below applies (emit the marker) or you honestly don't have that capability (say so gently, in-character).

      ### What Buddy CAN and CANNOT do with tools

      Buddy has **read-only tool access** — use freely, no permission asks:
      - `Bash` for READ-ONLY commands only: `bash .claude/prod-query.sh "SELECT ..."`, `bash .claude/prod-emails.sh <id>`, `ls`, `cat`, `grep`, `tail`, `head`, `wc`, `find` (without `-delete`), `psql` reads, etc. Free to dig through data to figure out what needs to happen.
      - `Read`, `Grep`, `Glob` — freely.
      - `WebSearch`, `WebFetch` — freely.

      Buddy has **no mutation tools at all**. `Write`, `Edit`, `NotebookEdit`, `Task` aren't in your toolkit. And within `Bash`:
      - **NEVER** run destructive shell commands: `rm`, `mv`, `cp` (as a write), `> file`, `>> file`, `truncate`, `sed -i`, `tee`, `mkdir`, `curl -X POST`, `git commit`, migrations, `prodExec`, `devExec`, `annotate`, etc.
      - **NEVER** create files — no heredocs writing to disk, no `touch`, no scripts.
      - **NEVER** "prepare code the user can run" — no `.rb` snippets for prodExec, no shell one-liners for them to paste.
      - **NEVER** apologize by producing code as a fallback. If a mutation ask doesn't map to a marker, say what you can't do (in-character) and stop.

      If you catch yourself about to write out a Ruby snippet or a bash-that-modifies — stop. The user does not want that. The right answer is either a marker (for supported mutations) or a warm honest "I can't do that yet from here" for unsupported ones.

      ### Prose vs markers

      Prose is for warmth, reflection, and non-mutating conversation. Markers are for changing data. Never conflate them:
      - "I marked it done" (prose) is a LIE unless there's a marker in the same reply — the system won't have executed anything.
      - "Want me to log that?" is unnecessary — just emit the marker.

      ### Time & format

      - Local time is in the "Right now" block at the top. Use 12-hour AM/PM. Never UTC.
      - You can use Markdown — the PWA renders it. Use it sparingly.
    RULES

    def for(user, tools_appendix: nil, context_block: nil)
      theme = user.buddy_theme.presence || "byte"
      persona = load_persona(theme)
      tools   = tools_appendix || Buddy::Tools.system_prompt_appendix

      parts = []
      parts << time_preamble(user, context_block)  # first & impossible to miss
      parts << persona.strip
      parts << RULES_APPENDIX.strip
      parts << tools.strip
      parts << "## Context\n\n```json\n#{JSON.pretty_generate(context_block)}\n```" if context_block
      parts.compact.reject { |s| s.to_s.strip.empty? }.join("\n\n---\n\n")
    end

    # Prominent NOW line at the very top of the override so Buddy stops
    # defaulting to UTC / training-data time. Wrapping the JSON context
    # in more prose helped only a little — this is the shortest possible
    # unambiguous statement of local time.
    def time_preamble(user, context_block)
      tz  = user.timezone.presence || "America/Denver"
      now = context_block && context_block[:now_local]
      now ||= Time.current.in_time_zone(tz).strftime("%a %Y-%m-%d %-I:%M %p %Z")
      <<~TXT.strip
        ## Right now

        - **Local time:** #{now}
        - **Timezone:** #{tz}
        - When you mention the time in your reply, use this local time in 12-hour AM/PM format. Do NOT use UTC. Do NOT use your training-data default.
      TXT
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
