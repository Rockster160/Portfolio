# What an eval run found, written as something an agent can be handed.
#
# The terminal output is for watching a run go past. This is for afterwards:
# one file per run holding every probe that missed, what it was asked, what it
# reached for instead, what it said while doing it, and which file owns the
# wording that decided. Piped into a coding agent it is a work order rather
# than a bug report — there is nothing left to go and look up.
#
# A SCENARIO run has none of that: no probe, no verdict, just 26 replies and a
# person's judgement. Those go in too, each beside the `want:` that says what a
# pass looks like, because the judging is the whole point of a scenario run and
# doing it from a scrollback means doing it once and then losing it.
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

  # Where this run writes. `report.md` is always the latest, and every run also
  # keeps a stamped copy under `runs/`.
  #
  # Both because the single file is the one people link to and the single file
  # is trivially lost: a run of the harness from a SPEC overwrote a 102-check
  # sweep with its own one-probe result, and the findings were gone. BUDDY_EVAL_DIR
  # is how a spec stays out of the way; `runs/` is how a real one survives the
  # next real one.
  def self.dir
    Rails.root.join(ENV["BUDDY_EVAL_DIR"].presence || DIR)
  end

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

    **"came back: ..." is not a description problem.** The tool was found and
    then failed — a name that matched nothing, or matched two things. Look at
    what the world seeds (`lib/buddy_eval_world.rb`) before touching any prose;
    a probe that can't run its tool is measuring nothing either way.

    **"nothing landed" means the call was made and DISPATCHED for real, and
    the database still doesn't show it.** That is the tool's `execute`, not its
    description.
  MD

  # What a scenario run has instead of a verdict: the sentence, what a pass
  # looks like, and what it actually said. Nothing here is a failure by itself —
  # it's the material for the judgement, and it leads with how to make one.
  TRANSCRIPT_PREAMBLE = <<~MD.freeze
    These turns have no automatic verdict. `want:` is what a pass looks like,
    written down beside what it actually said, so the judging can happen here
    rather than in a terminal scrollback that's already gone.

    What to look for, in rough order of how much damage it does:

    1. **A claim with no call under it.** "Fan's on low now" over an empty
       `called:` line is the worst failure Buddy has, because it is
       indistinguishable from success from the outside.
    2. **The same tool twice**, or two calls that make two of something the
       person asked for one of.
    3. **An argument that doesn't match the words** — a time in the past, a
       reminder whose text is the request rather than the nudge, a count the
       sentence didn't have.
    4. **The voice**: warmth over receipt, no fourth wall, no mention of tools
       or context, greeting that matches the hour. `app/service/buddy/personality.rb`
       and `app/service/buddy/personalities/` own that.

    A turn worth keeping goes back as a probe — `BUDDY_EDGE_PROBES` in
    `lib/tasks/buddy_eval.rake`, in the words it went wrong in.
  MD

  def initialize(failures:, unmet:, skipped:, passed:, prose: [], transcript: [], world: nil)
    @failures   = failures
    @prose      = prose
    @transcript = transcript
    @unmet      = unmet
    @skipped    = skipped
    @passed     = passed
    @world      = world
  end

  def write!(at:)
    dir = self.class.dir
    dir.mkpath
    md   = markdown(at)
    json = JSON.pretty_generate(as_json(at))
    dir.join("report.md").write(md)
    dir.join("report.json").write(json)

    stamped = dir.join("runs")
    stamped.mkpath
    stamped.join("#{at.strftime("%Y%m%d-%H%M%S")}.md").write(md)

    [dir.join("report.md"), dir.join("report.json")]
  end

  def as_json(at)
    {
      "ran_at"       => at.iso8601,
      "passed"       => @passed,
      "failed"       => @failures.length,
      "world"        => @world,
      "failures"     => @failures,
      "prose_flags"  => @prose,
      "transcript"   => @transcript,
      "unanswerable" => @unmet,
      "not_offered"  => @skipped,
    }
  end

  def markdown(at)
    out = ["# Buddy eval — #{at.strftime("%-d %b %Y, %-l:%M %p")}", ""]
    out << "#{@passed} of #{@passed + @failures.length} probes reached the right tool." if probed?
    if @transcript.any?
      out << "#{@transcript.length} #{"turn".pluralize(@transcript.length)}, " \
             "#{@prose.length} with something mechanically wrong."
    end
    out << ""

    if @failures.any?
      out << PREAMBLE
      @failures.each_with_index { |f, i| out.concat(section(f, i + 1)) }
    elsif probed?
      out << "Every probe reached its tool."
    end

    out.concat(prose_flags)
    out.concat(transcript)
    out.concat(footnotes)
    out.join("\n")
  end

  private

  def probed?
    @passed.positive? || @failures.any?
  end

  def section(failure, n)
    lines = ["", "## #{n}. #{failure["expected"]} — #{failure["said"].inspect}", ""]
    lines << "- **Wanted**: #{failure["wanted"]}"
    lines << "- **Got**: #{failure["detail"]}"
    lines << "- **Called**: #{failure["calls"].presence || "nothing"}"
    lines << "- **Known incident**: #{failure["case"]} — #{failure["note"]}" if failure["note"].present?
    lines << "- **Precondition**: #{failure["needs"]} — checked, and it was there" if failure["needs"].present?
    lines << "- **Owns the wording**: #{failure["files"].join(", ")}" if failure["files"].present?
    lines << "- **It replied**: #{failure["reply"].to_s.truncate(300).inspect}" if failure["reply"].present?
    lines
  end

  # The mechanical tone checks, which are cheap and catch real things: a marker
  # the person would have been shown, a reply that starts lowercase, a claim to
  # go and run something. Kept above the transcript because these are decided
  # rather than judged.
  def prose_flags
    return [] if @prose.empty?

    out = ["", "## Mechanically wrong", ""]
    out << "These tripped a check rather than a judgement. The wording lives in"
    out << "`app/service/buddy/personality.rb` and `app/service/buddy/personalities/`."
    @prose.each { |turn|
      out << ""
      out << "### #{turn["said"].inspect}"
      out << ""
      out << "- **Flag**: #{Array(turn["flags"]).join("; ")}"
      out << "- **Wanted**: #{turn["want"]}" if turn["want"].present?
      out << "- **Said**: #{turn["reply"].to_s.truncate(400).inspect}"
      out << "- **Called**: #{turn["calls"].presence || "nothing"}"
    }
    out
  end

  def transcript
    return [] if @transcript.empty?

    out = ["", "## Every turn, to be judged", "", TRANSCRIPT_PREAMBLE]
    @transcript.each_with_index { |turn, i|
      out << ""
      out << "### #{i + 1}. #{turn["said"].inspect}"
      out << ""
      out << "- **Want**: #{turn["want"]}" if turn["want"].present?
      out << "- **Said**: #{turn["reply"].to_s.truncate(400).inspect}"
      out << "- **Face**: #{turn["mood"]}" if turn["mood"].present?
      out << "- **Called**: #{turn["calls"].presence || "nothing"}"
      out << "- **Flagged**: #{Array(turn["flags"]).join("; ")}" if Array(turn["flags"]).any?
    }
    out
  end

  def footnotes
    out = []
    if @unmet.any?
      out << ""
      out << "## Not answerable from this person's data"
      out << ""
      out << "Each of these was CHECKED against the database before being filed here"
      out << "(`lib/buddy_eval_needs.rb`), so the thing genuinely isn't there. Not a"
      out << "description problem — either build it into `lib/buddy_eval_world.rb`, or"
      out << "leave the probe alone if it's live state nothing can seed."
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
