module Buddy
  # Finding, and naming, things in the physical inventory.
  #
  # The inventory is one tree of `Box` rows where a box and an item are the same
  # kind of row - `empty` is the only difference, and it means "nothing is
  # inside this", which is what makes it an item rather than a container. So
  # "the camping tote" and "the headlamp inside it" resolve through exactly the
  # same path, and moving one into the other is the same write either way.
  #
  # None of it ships in the prompt (Buddy::Features::SECTIONS[:inventory] is
  # empty on purpose - see there). Everything a tool knows about the inventory,
  # it knows because it asked here.
  module Inventory
    module_function

    LIMIT = 15

    # A param_key off a QR label: four to seven characters, no O/I because they
    # were never minted (`Box#set_param_key` excludes 0 and 1 and maps them back
    # on lookup, so a person reading "0" off a label still lands right).
    HANDLE_RX = /\A[A-Z2-9]{4,7}\z/

    # What somebody says for "not inside anything any more". The tree's own
    # word for it on screen is "Everything", which reads as the opposite, so it
    # is in here alongside the plainer ones.
    TOP_LEVEL_WORDS = %w[top everything root none nowhere outside].freeze

    # How big a branch `remove_inventory_item` will take out in one go. The
    # whole subtree is snapshotted onto the proposal button so the undo can put
    # it back, and that button is a jsonb column on a chat row, not an archive.
    # Past this the honest answer is that the Inventory app should do it.
    REMOVE_CAP = 25

    # Below this a typo is indistinguishable from a different thing entirely.
    # The tree really does hold rows called "AA", "C" and "D" - one edit apart
    # from each other and from half the alphabet - so the nearest-neighbour
    # fallback every other resolver leans on would answer "B" with a confident
    # box of D batteries. Anything this short has to match exactly or not at all.
    FUZZY_FLOOR = 4
    FUZZY_TOLERANCE = 0.34

    # ---- lookup ----

    # A fresh query every time, never `user.boxes`. A has_many caches the
    # moment it's read, and a turn can file something and then move it in the
    # same breath - "start a bin in the attic and put the sleeping bags in it"
    # is two calls against one ToolContext, and off a cached association the
    # second one cannot see what the first one just made.
    def all_for(user)
      ::Box.where(user_id: user.id).with_photos
    end

    # Everything matching, nearest-fit first. Used both by `search_inventory`
    # (which shows them) and by `resolve` (which insists on exactly one).
    def matches(user, needle)
      raw = needle.to_s.strip
      return [] if raw.blank?

      pool   = all_for(user).to_a
      needle = raw.delete_prefix("#")

      # A leading `#` is how every row of a search result is labelled, so it
      # means the handle and gets tried first. Without the `#` the handle comes
      # LAST: four capitals is also what a name like "Dice" looks like once
      # it's upcased, and a real box called Dice must not lose to a param_key
      # that happens to spell it.
      handled = by_handle(pool, needle) if raw.start_with?("#")
      return [handled] if handled

      exact = pool.select { |box| box.name.to_s.casecmp?(needle) }
      return exact if exact.any?

      contained = pool.select { |box| box.name.to_s.downcase.include?(needle.downcase) }
      return rank(contained, needle) if contained.any?

      handled = by_handle(pool, needle)
      return [handled] if handled

      near = nearest(pool, needle)
      near ? [near] : []
    end

    # The box a resolved payload points at, read back at execute time. Raises
    # if it's gone between the confirm and the tap, which is the honest answer
    # - the alternative is a receipt for a row that isn't there.
    def find!(user, key)
      ::Box.where(user_id: user.id).find_by(param_key: key) || raise("that box isn't in the inventory any more")
    end

    # One box, or a raised sentence saying why not. The sentence is what Buddy
    # says back, so it carries the near misses: "there are two called Smellies"
    # with both paths beats picking one, because the wrong tote is a wrong
    # answer that looks exactly like a right one.
    def resolve!(user, needle, verb: "find", arg: :item)
      found = matches(user, needle)
      raise "nothing in the inventory matching #{needle.to_s.strip.inspect}" if found.empty?
      return found.first if found.length == 1

      # Same name in two places is the ordinary shape of an inventory, so an
      # exact tie has to be handed back rather than guessed at.
      tied = found.select { |box| box.name.to_s.casecmp?(needle.to_s.strip.delete_prefix("#")) }
      raise ambiguous(tied, needle, verb, arg: arg) if tied.length > 1

      found.first
    end

    # The tie, as a choice rather than only a complaint. Each option answers
    # with the box's #HANDLE, which is exact where the name was not, and says
    # where it lives underneath - which is the only thing that tells two boxes
    # called Smellies apart.
    def ambiguous(tied, needle, verb, arg: :item)
      shown = tied.first(Buddy::Disambiguation::MAX_OPTIONS)
      where = shown.map { |box| "#{handle(box)} in #{location_of(box)}" }
      ::Buddy::Ambiguous.new(
        "there's more than one #{needle.to_s.strip} - #{where.join(", ")}. Ask which one to #{verb}",
        arg:     arg,
        prompt:  "There's more than one #{needle.to_s.strip} in the inventory. Which one?",
        options: shown.map { |box|
          { value: handle(box), label: box.name.to_s, description: "in #{location_of(box)}" }
        },
      )
    end

    def by_handle(pool, needle)
      key = needle.to_s.strip.upcase.gsub("0", "O").gsub("1", "I")
      return nil unless key.match?(HANDLE_RX)

      pool.find { |box| box.param_key.to_s == key }
    end

    # Rank by how much of the name the needle accounts for, the same instinct
    # ToolContext#best_contained uses: "tent" is most of "Tent" and a fifth of
    # "Tent Stakes And Guylines", and the shorter name is the one that's ABOUT
    # the thing you said.
    def rank(boxes, needle)
      boxes.sort_by { |box| -(needle.length.to_f / box.name.to_s.length) }
    end

    def nearest(pool, needle)
      return nil if needle.length < FUZZY_FLOOR

      allowed = [(needle.length * FUZZY_TOLERANCE).round, 1].max
      scored = pool.map { |box| [box, distance(box.name.to_s.downcase, needle.downcase)] }
      best, gap = scored.min_by(&:last)
      best if gap && gap <= allowed
    end

    def distance(a, b)
      Buddy::ToolContext.levenshtein(a, b)
    end

    # ---- searching ----

    # `query` is a name fragment; `inside` narrows to one container's whole
    # subtree. With no query at all, `inside` reads as "what's in here" and the
    # answer is that container's direct contents rather than everything under
    # it - "what's in the garage" wants the shelves, not 60 screws.
    def search(user:, query: nil, inside: nil, limit: LIMIT)
      container = inside.present? ? resolve!(user, inside, verb: "look in", arg: :inside) : nil
      scope     = all_for(user)
      scope     = scope.within(container.param_key) if container

      if query.blank?
        raise "say what to look for" if container.nil?

        items = container.contents.to_a
        return { items: items.first(limit), total: items.length, container: container }
      end

      # Name, notes and description - the THING - and deliberately not
      # `hierarchy`, even though the Inventory app's own search includes it.
      # The path is a run of words from every ancestor, so a one-word query
      # matches every item under any box whose name happens to contain it:
      # searching the battery drawer for "a" came back with the C cells,
      # because they sit under "Basement". Where to look is what `inside` is
      # for, and the path is on every row of the answer either way.
      needle = "%#{query.to_s.strip.downcase}%"
      scope  = scope.where(
        "LOWER(name) LIKE :q OR LOWER(COALESCE(notes, '')) LIKE :q OR " \
        "LOWER(COALESCE(description, '')) LIKE :q",
        q: needle,
      )
      items = rank(scope.to_a, query.to_s.strip)

      { items: items.first(limit), total: items.length, container: container }
    end

    # ---- photos ----

    # Attachments the models and the browser can all read, on one message.
    def images_on(message)
      return [] if message.nil? || !message.files.attached?

      message.files.select { |file| ByteImageNormalizer::PASSTHROUGH_TYPES.include?(file.content_type.to_s) }
    end

    # A photo moving between a chat message and a box gets its own COPY of the
    # bytes rather than a second attachment on the same blob. ActiveStorage
    # purges a blob when the last thing pointing at it goes, and both ends
    # delete on their own schedule - clearing an old thread would otherwise
    # take the photo off the box, and removing the box would blank the picture
    # out of the conversation it arrived in.
    def copy_blob(blob)
      ::ActiveStorage::Blob.create_and_upload!(
        io:           StringIO.new(blob.download),
        filename:     blob.filename.to_s,
        content_type: blob.content_type,
      )
    end

    # Puts the box's photos in front of them, as a real message in the thread.
    #
    # Deliberately NOT through Buddy::CompanionDelivery: that pushes to their
    # phone, which is right for a doorbell frame arriving unasked and wrong for
    # a picture they asked to see one second ago in the thread they're looking
    # at. Same row shape, same broadcast, no buzz.
    def post_photos!(conversation:, user:, box:, images:)
      message = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         "#{box.name} — #{path_of(box)}",
        metadata:     { "kind" => "buddy", "source" => "inventory", "box_key" => box.param_key },
        delivered_at: Time.current,
      )
      images.each { |image| message.files.attach(copy_blob(image.file.blob)) }
      Buddy::ActivityChip.broadcast(user, message)
      message
    end

    # ---- naming ----

    def handle(box)
      "##{box.param_key}"
    end

    # Where the thing IS, which is the whole question most of the time. A box
    # at the top level isn't inside anything, and saying so plainly beats an
    # empty string that reads like a missing answer.
    def location_of(box)
      trail = Array(box.hierarchy_data).map { |crumb| crumb[:name] || crumb["name"] }.compact
      trail.any? ? trail.join(" > ") : "the top level"
    end

    # The box's OWN full path, which is where a thing filed into it ends up.
    # `hierarchy` is maintained on save and already ends with the box's name;
    # a top-level box has none yet, and its name is the whole path.
    def path_of(box)
      box.hierarchy.presence || box.name.to_s
    end

    def rows(boxes)
      boxes = Array(boxes)
      held  = child_counts(boxes)
      boxes.map { |box| row(box, held: held[box.param_key].to_i) }
    end

    # One query for a whole page of results instead of one per container.
    def child_counts(boxes)
      keys = boxes.reject(&:empty).map(&:param_key)
      return {} if keys.empty?

      ::Box.where(parent_key: keys).group(:parent_key).count
    end

    def row(box, held: nil)
      held = box.boxes.size if held.nil?
      parts = [handle(box), box.name.to_s, "in #{location_of(box)}"]
      parts << "holds #{held} #{"thing".pluralize(held)}" unless box.empty?
      parts << box.notes.to_s.squish if box.notes.present?
      parts << "#{box.images.size} #{"photo".pluralize(box.images.size)}" if box.images.any?
      parts.join(" · ")
    end
  end
end
