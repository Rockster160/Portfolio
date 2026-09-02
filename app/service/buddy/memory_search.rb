module Buddy
  # Everything one person's companion holds about them, searched.
  #
  # This is the retrieval half of retiring `MEMORY_RECALL_LIMIT`. The old design
  # injected the 30 highest-priority memories into every prompt and reached
  # nothing else; anything past the cap was simply unreachable, and because the
  # ordering was by reinforcement count, the first rows dropped were the ones
  # mentioned once and never repeated. "We forgot the sleeping bags" is exactly
  # that shape: said once, useless for months, and the whole point of keeping it.
  #
  # So recall is now: preferences ship inline (see
  # Buddy::Personality#memories_block), and everything else is found here — by
  # tag when the conversation names a subject, by text when the person is
  # groping for a half-remembered thing.
  #
  # Text matching covers the content, the summary AND every note, because on a
  # thread added to five times the searchable words are usually in the notes
  # rather than the sentence that started it.
  module MemorySearch
    module_function

    LIMIT = 12

    # `kinds` narrows to particular record types — the stash tools pass
    # `[:stash]` so "what am I holding" can't start returning preferences.
    # `status: :live` for still-open only, `:all` for everything including
    # finished and dropped. Default is everything: someone asking about an old
    # thought rarely remembers whether they ever closed it.
    def call(user:, query: nil, tags: nil, kinds: nil, status: :all, limit: LIMIT, threads_only: false)
      scope = BuddyMemory.where(user_id: user.id)
      scope = scope.where(kind: Array(kinds).map { |k| BuddyMemory.kinds[k.to_s] }.compact) if kinds.present?
      scope = scope.live if status.to_sym == :live
      scope = matching(scope, query)
      scope = tagged(scope, tags)
      scope = scope.where(id: BuddyMemoryNote.select(:buddy_memory_id)) if threads_only

      ordered = scope.order(Arel.sql("severity DESC, COALESCE(last_touched_at, created_at) DESC"))
      { memories: ordered.limit(limit).includes(:notes).to_a, total: scope.count }
    end

    # A plain OR across the content, the summary and the notes. Deliberately not
    # the tokenizing query syntax the events search uses: a memory has no fields
    # worth addressing individually, and every term someone would search for is
    # somewhere in the prose.
    def matching(scope, query)
      words = query.to_s.split(/\s+/).map(&:strip).compact_blank
      return scope if words.empty?

      words.reduce(scope) { |acc, word|
        like = "%#{sanitize_like(word)}%"
        acc.where(
          "buddy_memories.content ILIKE :q OR buddy_memories.summary ILIKE :q OR buddy_memories.id IN (" \
          "SELECT buddy_memory_id FROM buddy_memory_notes WHERE body ILIKE :q)",
          q: like,
        )
      }
    end

    # Tag containment, OR across the terms — someone asking about camping wants
    # anything touching camping, not the intersection of every word they said.
    #
    # `category` is matched by the same terms. It is a separate column for the
    # stash pile's sake, and a caller searching "work" should not have to know
    # which of the two holds the word.
    def tagged(scope, tags)
      terms = Array(tags).map { |t| t.to_s.downcase.strip }.reject(&:empty?).uniq
      return scope if terms.empty?

      cats = terms.filter_map { |t| BuddyMemory.categories[t] }
      sql  = terms.map { "buddy_memories.tags @> ?" }
      args = terms.map { |t| [t].to_json }
      if cats.any?
        sql << "buddy_memories.category IN (?)"
        args << cats
      end
      scope.where(sql.join(" OR "), *args)
    end

    def sanitize_like(word)
      word.gsub(/[\\%_]/) { |c| "\\#{c}" }
    end

    # One line per hit, id first because every tool that acts on one takes it. A
    # thread reports how much is in it and the newest thing said, since that is
    # nearly always more use than the seed for telling threads apart.
    def rows(memories, now=Time.current)
      memories.map { |memory| row(memory, now) }
    end

    def row(memory, now=Time.current)
      bits = ["##{memory.id}"]
      bits << memory.summary.presence.to_s.strip if memory.summary.present?
      bits << memory.content.to_s.strip.truncate(90) if memory.summary.blank?
      bits << "(#{labels(memory, now).join(", ")})"
      latest = memory.notes.last
      bits << "— latest: #{latest.body.to_s.strip.truncate(70)}" if latest
      bits.join(" ")
    end

    def labels(memory, now)
      out = [memory.kind]
      out << memory.category_label.downcase if memory.category.present?
      out << memory.status unless memory.status_active?
      out.concat(memory.tag_list)
      out << (memory.thread_label(now) || "held #{memory.waiting_label(now)}")
      out
    end
  end
end
