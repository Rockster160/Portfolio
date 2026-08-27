module Buddy
  # Pictures, found by what is in them.
  #
  # The same shape as Buddy::MemorySearch and for the same reason: a plain OR
  # across the words, because a description has no fields worth addressing
  # individually and the thing somebody half remembers could be anywhere in it.
  module PhotoSearch
    module_function

    LIMIT = 8

    def call(user:, query: nil, since: nil, until_at: nil, box: nil, limit: LIMIT)
      scope = ImageDescription.where(user_id: user.id)
      scope = matching(scope, query)
      scope = scope.where(taken_at: since..) if since
      scope = scope.where(taken_at: ..until_at) if until_at
      scope = scope.where(box_key: box) if box.present?

      { photos: scope.recent.limit(limit).to_a, total: scope.count }
    end

    # Every word has to be in there somewhere, in the body or the tags. AND
    # rather than OR across the words: "the blue bike" narrowing to pictures
    # with both is the point, where anything blue OR any bike is the whole
    # album.
    def matching(scope, query)
      words = query.to_s.split(/\s+/).map(&:strip).compact_blank
      return scope if words.empty?

      words.reduce(scope) { |acc, word|
        like = "%#{ActiveRecord::Base.sanitize_sql_like(word)}%"
        acc.where(
          "image_descriptions.body ILIKE :q OR EXISTS (" \
          "SELECT 1 FROM jsonb_array_elements_text(image_descriptions.tags) tag WHERE tag ILIKE :q)",
          q: like,
        )
      }
    end

    def rows(photos)
      photos.map(&:wire)
    end
  end
end
