# One change applied to many emails at once, from the list view's batch bar.
#
# Done as `update_all` rather than a save per row: "every email matching this
# search" can be thousands, and nothing on Email listens for a save.
# rubocop:disable Rails/SkipsModelValidations
module Emails::Batch
  module_function

  OPERATIONS = [:archive, :unarchive, :read, :unread, :add_tags, :remove_tags].freeze

  class UnknownOperation < ::StandardError; end

  # Returns how many emails the change actually landed on - an email already in
  # that state is not counted, so "Archived 0" means there was nothing to do.
  def call(scope, operation, tags: nil)
    operation = operation.to_s.to_sym
    raise UnknownOperation, operation.inspect unless operation.in?(OPERATIONS)

    now = ::Time.current
    case operation
    when :archive   then scope.not_archived.update_all(archived_at: now, updated_at: now)
    when :unarchive then scope.archived.update_all(archived_at: nil, updated_at: now)
    when :read      then scope.unread.update_all(read_at: now, updated_at: now)
    when :unread    then scope.read.update_all(read_at: nil, updated_at: now)
    when :add_tags    then add_tags(scope, ::GroupTaggable.normalize(tags), now)
    when :remove_tags then remove_tags(scope, ::GroupTaggable.normalize(tags), now)
    end
  end

  # Per tag, so a row that already carries it - in any case - is left alone
  # and the spelling it was first given is kept.
  def add_tags(scope, tags, now)
    touched = tags.flat_map { |tag|
      ids = scope.where.not(id: ::Email.tagged(tag).select(:id)).ids
      ::Email.where(id: ids).update_all(["tags = array_append(tags, ?), updated_at = ?", tag, now])
      ids
    }
    touched.uniq.size
  end

  def remove_tags(scope, tags, now)
    return 0 if tags.empty?

    scope.tagged(tags).update_all(
      [
        "tags = ARRAY(SELECT t FROM unnest(tags) t WHERE LOWER(t) <> ALL (ARRAY[?])), updated_at = ?",
        tags.map(&:downcase),
        now,
      ],
    )
  end
end
# rubocop:enable Rails/SkipsModelValidations
