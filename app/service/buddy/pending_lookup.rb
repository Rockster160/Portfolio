module Buddy
  # Finding the reminder or watch somebody means, and saying which one it was.
  #
  # Reminders and watches are separate tables that behave identically from the
  # person's side - both are "the thing you're going to tell me about" - and get
  # referred to interchangeably. Prod 2825: "I don't care if it's a reminder or
  # an agenda or a watch, I'm specifically asking it to be removed." So the
  # lookup spans both and the taxonomy never reaches the conversation.
  #
  # Two rules come out of prod 2817-2834, where the right watch was removed on
  # the first attempt and then the wrong one three times after:
  #
  # 1. NOTHING here silently chooses between two candidates. A watch's `body` is
  #    prose somebody wrote, and two can carry identical prose while listening
  #    for entirely different things:
  #
  #      17  "🔔 Someone's at the doorbell."  location:doorbell type:rang
  #      18  "🔔 Someone's at the doorbell."  location:/^Doorbell$/ subject:person
  #
  #    A `.first` on a LIKE across those is a coin flip, and it landed wrong.
  #
  # 2. A switched-off row is still a row. The panel's toggle sets `cancelled_at`
  #    and leaves it listed, so "it's still in the Reminders list" was true and
  #    "I cancelled it" was also true. Both are findable here, and removing one
  #    means removing it.
  module PendingLookup
    module_function

    # One row, either kind, with everything needed to name it.
    Row = Struct.new(:record, :kind, keyword_init: true) do
      def id = record.id

      def noun = kind == :watch ? "watch" : "reminder"

      def off? = record.cancelled_at.present?

      def summary
        record.body.to_s.strip.presence&.truncate(60) || "##{record.id}"
      end

      # What separates this row from another one worded the same. For a watch
      # that's the condition it listens for; for a reminder, when it goes off.
      def detail
        return record.listener.presence || human_when if kind == :watch

        record.fire_at && Buddy::TimeParser.friendly(record.fire_at, user: record.user)
      end

      def disambiguated = "##{record.id} (#{detail || noun})"

      def human_when
        meta = record.metadata
        meta.is_a?(Hash) ? meta["human_when"].to_s.presence : nil
      end

      # Gone means GONE. Byte used to set `cancelled_at`, which is the panel's
      # OFF switch rather than its delete - the row stayed listed, looking
      # disabled, and stayed matchable, so the next attempt could find and
      # re-cancel something already cancelled.
      #
      # Undo restores the whole row, which is the only reason deleting outright
      # is safe here.
      def destroy!
        attrs = record.attributes.except("id", "created_at", "updated_at")
        label = summary
        record.destroy!
        { op: :recreated, model: record.class.name, attrs: attrs, summary: "put #{label} back" }
      end
    end

    def find(user, kind, id)
      klass  = kind.to_s == "watch" ? BuddyWatch : BuddyReminder
      record = klass.find_by(id: id, user_id: user.id)
      record && Row.new(record: record, kind: kind.to_s.to_sym)
    end

    # Everything the needle could mean. A numeric needle is an id and matches at
    # most one; anything else is a substring and may match several, which is the
    # caller's problem to surface rather than ours to resolve.
    #
    # Switched-off rows are included on purpose: they still exist, they're still
    # on the panel, and "delete that one" about one of them is a real request.
    def matching(user, needle)
      needle = needle.to_s.strip
      rows   = removable(user)
      return rows.select { |r| r.id == needle.to_i } if needle.match?(/\A\d+\z/)

      rows.select { |r| r.record.body.to_s.downcase.include?(needle.downcase) }
    end

    # Live or merely switched off - anything still sitting on the panel.
    def removable(user)
      [
        *BuddyReminder.where(user_id: user.id, fired_at: nil).order(:fire_at).map { |r| Row.new(record: r, kind: :reminder) },
        *BuddyWatch.where(user_id: user.id, fired_at: nil).order(:created_at).map { |w| Row.new(record: w, kind: :watch) },
      ]
    end
  end
end
