module Buddy
  # One person's held thoughts, searched across their whole history rather than
  # the fifteen most recent that ride in the prompt.
  #
  # The prompt's "Things you're holding" block is a live list capped at
  # OPEN_LOOP_LIMIT and scoped to what's still open, which is right for "am I
  # about to drop something" and useless for "what was that thing I said about
  # the greenhouse in the spring". Closed threads are the interesting ones there
  # — an idea gets finished and then comes back around — so this searches every
  # status by default and lets the caller narrow.
  #
  # Text matching covers the seed, the companion's summary, AND every note,
  # because on a thread that's been added to five times the searchable words are
  # usually in the notes rather than the sentence that started it.
  module IdeaSearch
    module_function

    LIMIT      = 12
    NOTE_PEEK  = 2

    # `status: :live` for still-open only, `:all` for everything including
    # finished and dropped. Default is everything: someone asking about an old
    # thought rarely remembers whether they ever closed it.
    def call(user:, query: nil, status: :all, limit: LIMIT, threads_only: false)
      scope = user.buddy_ideas
      scope = scope.live if status.to_sym == :live
      scope = matching(scope, query)
      scope = scope.where(id: BuddyIdeaNote.select(:buddy_idea_id)) if threads_only

      ordered = scope.order(Arel.sql("COALESCE(last_touched_at, created_at) DESC"))
      { ideas: ordered.limit(limit).includes(:notes).to_a, total: scope.count }
    end

    # A plain OR across the seed, the summary and the notes. Deliberately not
    # the Tokenizing query syntax the events search uses: an idea has no fields
    # worth addressing individually, and every term someone would search for is
    # somewhere in the prose.
    def matching(scope, query)
      words = query.to_s.split(/\s+/).map(&:strip).compact_blank
      return scope if words.empty?

      words.reduce(scope) { |acc, word|
        like = "%#{sanitize_like(word)}%"
        acc.where(
          "buddy_ideas.body ILIKE :q OR buddy_ideas.summary ILIKE :q OR buddy_ideas.id IN (" \
          "SELECT buddy_idea_id FROM buddy_idea_notes WHERE body ILIKE :q)",
          q: like,
        )
      }
    end

    def sanitize_like(word)
      word.gsub(/[\\%_]/) { |c| "\\#{c}" }
    end

    # One line per hit, id first because every tool that acts on one takes it.
    # A thread reports how much is in it and the newest thing said, since that
    # is nearly always more use than the seed for telling threads apart.
    def rows(ideas, now=Time.current)
      ideas.map { |idea| row(idea, now) }
    end

    def row(idea, now=Time.current)
      bits = ["##{idea.id}"]
      bits << idea.summary.presence.to_s.strip if idea.summary.present?
      bits << idea.body.to_s.strip.truncate(90) if idea.summary.blank?
      bits << "(#{tags(idea, now).join(", ")})"
      latest = idea.notes.last
      bits << "— latest: #{latest.body.to_s.strip.truncate(70)}" if latest
      bits.join(" ")
    end

    def tags(idea, now)
      out = [idea.category_label.downcase]
      out << idea.status unless idea.status_active?
      out << (idea.thread_label(now) || "held #{idea.waiting_label(now.to_date)}")
      out
    end
  end
end
