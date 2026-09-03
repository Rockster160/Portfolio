# Ranked search over job applications.
#
# ApplicationRecord's `search` DSL is a FILTER — `company:netflix` narrows a
# relation and hands it back in whatever order the scope had. What a job search
# needs is an ORDER: type "netflix" and Netflix comes first, above an
# application whose note happens to mention Netflix and which was touched more
# recently. That is a ranking problem, and SQL is a poor place to express field
# weights, so scoring happens here in Ruby over one preloaded query.
#
# Volume makes this safe: a person has tens of applications, not millions.
class JobSearch
  # Where a match was found, and what that is worth. The whole design is in
  # this table — the company's own name outranks everything else by enough that
  # no combination of weaker hits can climb over it, which is the difference
  # between a search that finds Netflix and one that finds four things that
  # said Netflix.
  #
  #   100 — the company, exactly
  #    80 — the company, from the start ("net" → Netflix)
  #    60 — the company, anywhere ("flix" → Netflix)
  #    40 — the company, near enough ("netflx" → Netflix)
  #    30 — the role
  #    25 — who a note says you spoke to
  #    20 — where the listing came from, or the application's status
  #    18 — what kind of thing a note was ("rejected")
  #    12 — the words in a note
  #     8 — a link
  WEIGHTS = {
    company_exact:  100,
    company_prefix: 80,
    company_part:   60,
    company_fuzzy:  40,
    role:           30,
    spoke_to:       25,
    source:         20,
    status:         20,
    tag:            18,
    body:           12,
    link:           8,
  }.freeze

  # A typo allowance proportional to the word, floored at one edit so short
  # names ("Visa") still tolerate a slip. Same ratio Buddy resolves chore names
  # with, for the same reason: about a third lets ordinary typos through while a
  # word that simply isn't there matches nothing.
  FUZZY_RATIO = Buddy::ToolContext::FUZZY_TOLERANCE

  # `jobs` is any relation — already narrowed by status, if the page did that —
  # so filtering and searching compose instead of competing.
  def self.call(jobs, query)
    new(jobs, query).results
  end

  def initialize(jobs, query)
    @jobs = jobs
    @tokens = query.to_s.downcase.split(/\s+/).compact_blank
  end

  def results
    return @jobs.to_a if @tokens.empty?

    # Every token has to land somewhere — `score` returns nil the moment one
    # doesn't. A second word in a search is there to narrow it; "netflix
    # recruiter" meaning "either of those" would widen it instead, and hand
    # back more than the first word did.
    scored = @jobs.includes(:notes).filter_map { |job|
      total = score(job)
      [job, total] if total
    }
    scored.sort_by { |job, total| [-total, -activity(job)] }.map(&:first)
  end

  private

  # Nil when a token found nothing at all, which is what drops the row.
  def score(job)
    fields = fields_for(job)

    @tokens.sum { |token|
      best = best_for(token, fields)
      return nil if best.zero?

      best
    }
  end

  # Flattened once per job rather than per token — the notes are the expensive
  # half and they don't change between tokens.
  def fields_for(job)
    notes = job.notes.to_a

    {
      company: job.company.to_s.downcase,
      role:    job.role.to_s.downcase,
      source:  job.source.to_s.downcase,
      status:  job.status.to_s.downcase,
      links:   ([job.url] + notes.map(&:url)).compact_blank.map(&:downcase),
      spoke:   notes.filter_map { |n| n.spoke_to.presence&.downcase },
      tags:    notes.map { |n| n.tag_label.downcase }.uniq,
      bodies:  notes.filter_map { |n| n.body.presence&.downcase },
      sources: notes.filter_map { |n| n.source.presence&.downcase },
    }
  end

  def best_for(token, fields)
    scores = [
      company_score(token, fields[:company]),
      (WEIGHTS[:role] if fields[:role].include?(token)),
      (WEIGHTS[:status] if fields[:status] == token),
      (WEIGHTS[:source] if fields[:source].include?(token)),
      (WEIGHTS[:spoke_to] if fields[:spoke].any? { |v| v.include?(token) }),
      (WEIGHTS[:tag] if fields[:tags].any? { |v| v.include?(token) }),
      (WEIGHTS[:source] if fields[:sources].any? { |v| v.include?(token) }),
      (WEIGHTS[:body] if fields[:bodies].any? { |v| v.include?(token) }),
      (WEIGHTS[:link] if fields[:links].any? { |v| v.include?(token) }),
    ]

    scores.compact.max.to_i
  end

  # Fuzzy applies to the company and nowhere else. A near-miss on a name is a
  # typo worth catching; a near-miss inside a paragraph of notes is noise, and
  # an edit distance per note per token is the one thing here that would cost
  # anything.
  def company_score(token, company)
    return 0 if company.blank?
    return WEIGHTS[:company_exact] if company == token
    return WEIGHTS[:company_prefix] if company.start_with?(token)
    return WEIGHTS[:company_part] if company.include?(token)
    return WEIGHTS[:company_fuzzy] if near?(token, company)

    0
  end

  # Measured against each word of the name as well as the whole of it, so
  # "corprate" still finds "Corporate Tools" — a typo in one word shouldn't
  # have to be within a third of the entire name to count.
  def near?(token, company)
    ([company] + company.split(/[\s\-&]+/)).any? { |candidate|
      next false if candidate.blank?

      allowance = [1, (candidate.length * FUZZY_RATIO).floor].max
      Buddy::ToolContext.levenshtein(token, candidate) <= allowance
    }
  end

  def activity(job)
    (job.last_activity_at || job.created_at).to_i
  end
end
