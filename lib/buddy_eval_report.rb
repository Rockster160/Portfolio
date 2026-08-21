# The failures from an eval run, written as something an agent can be handed.
#
# The terminal output is for watching a run go past. This is for afterwards:
# one file per run holding every probe that missed, what it was asked, what it
# reached for instead, what it said while doing it, and which file owns the
# wording that decided. Piped into a coding agent it is a work order rather
# than a bug report — there is nothing left to go and look up.
#
# Two formats from the same data:
#   report.md    — what you paste into an agent
#   report.json  — the same, for anything that wants to read it programmatically
#
# The MD leads with the instruction rather than the data, because a file that
# opens with a list of failures gets acted on one failure at a time, and the
# first thing worth saying is that the description is usually the lever and
# usually the wrong one to pull twice.
class BuddyEvalReport
  DIR = "tmp/buddy_eval".freeze

  PREAMBLE = <<~MD.freeze
    Each section below is one thing Buddy was told, and the tool it reached for
    instead of the right one. They came from `rake buddy:eval_tools`, which says
    a plain sentence to the real model with the real tool schemas and watches
    which tool comes back.

    **Reading a failure.** "Missed X, called Y" means the two descriptions don't
    separate cleanly for that sentence — the fix is usually in one of the two
    named files, and usually in the part of the description that says when NOT
    to use it. "Right tool, wrong arguments" is a different problem: the tool
    was found and its arguments weren't understood, which is the arg
    descriptions rather than the tool's.

    **Before rewriting a description, check whether it has already been
    rewritten for this.** Several of these have had three passes, and each pass
    was followed by the same failure wearing different words. If the prose
    already says the thing plainly, prose is not the lever — the fix is a gate
    in `app/service/buddy/gpt/turn.rb`, which reads the REQUEST rather than
    hoping the reply behaves.

    **Never add a rule that names what not to say.** A phrase written into the
    prompt as forbidden gets said. State the wanted behavior instead.

    **A `known incident` line means this exact failure has happened in
    production before.** Those are the ones worth fixing properly rather than
    patching the symptom.
  MD

  def initialize(failures:, unmet:, skipped:, passed:, world: nil)
    @failures = failures
    @unmet    = unmet
    @skipped  = skipped
    @passed   = passed
    @world    = world
  end

  def write!(at:)
    dir = Rails.root.join(DIR)
    dir.mkpath
    dir.join("report.md").write(markdown(at))
    dir.join("report.json").write(JSON.pretty_generate(as_json(at)))
    [dir.join("report.md"), dir.join("report.json")]
  end

  def as_json(at)
    {
      "ran_at"       => at.iso8601,
      "passed"       => @passed,
      "failed"       => @failures.length,
      "world"        => @world,
      "failures"     => @failures,
      "unanswerable" => @unmet,
      "not_offered"  => @skipped,
    }
  end

  def markdown(at)
    out = ["# Buddy tool-selection failures — #{at.strftime("%-d %b %Y, %-l:%M %p")}", ""]
    out << "#{@passed} of #{@passed + @failures.length} probes reached the right tool."
    out << ""

    if @failures.empty?
      out << "Nothing to fix."
    else
      out << PREAMBLE
      @failures.each_with_index { |f, i| out.concat(section(f, i + 1)) }
    end

    out.concat(footnotes)
    out.join("\n")
  end

  private

  def section(failure, n)
    lines = ["", "## #{n}. #{failure["expected"]} — #{failure["said"].inspect}", ""]
    lines << "- **Wanted**: #{failure["wanted"]}"
    lines << "- **Got**: #{failure["detail"]}"
    lines << "- **Called**: #{failure["calls"].presence || "nothing"}"
    lines << "- **Known incident**: #{failure["case"]} — #{failure["note"]}" if failure["note"].present?
    lines << "- **Owns the wording**: #{failure["files"].join(", ")}" if failure["files"].present?
    lines << "- **It replied**: #{failure["reply"].to_s.truncate(300).inspect}" if failure["reply"].present?
    lines
  end

  def footnotes
    out = []
    if @unmet.any?
      out << ""
      out << "## Not answerable from this person's data"
      out << ""
      out << "These missed because the thing they ask about isn't there. Not a"
      out << "description problem — either build it into `lib/buddy_eval_world.rb`"
      out << "or leave the probe alone."
      out << ""
      @unmet.each { |u| out << "- #{u}" }
    end

    if @skipped.any?
      out << ""
      out << "## Never offered"
      out << ""
      out << "Feature switched off for this person, so the model was never shown the tool."
      out << ""
      @skipped.each { |s| out << "- #{s}" }
    end
    out
  end
end
