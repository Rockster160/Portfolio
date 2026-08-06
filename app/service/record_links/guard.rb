module RecordLinks
  # Stops a propagation eating itself.
  #
  # `Jil.trigger` runs synchronously on the calling thread, has no depth
  # counter, and every write the propagator makes fires more triggers. Two
  # linked list-item rules point straight at each other — adding an item marks a
  # chore due, marking a chore due adds the item — so without something here
  # the pair spins until the stack gives out. Under Jil that was survivable only
  # by accident: `Chore.mark_due` happened to no-op when already stamped, which
  # spec/service/jil/item_chore_sync_loop_spec.rb pins at "between 2 and 4
  # round trips" rather than at zero.
  #
  # A blanket "ignore anything nested" would be simpler and wrong, because real
  # chains are two and three hops long and every one of them is wanted: an event
  # completes a chore, and completing that chore takes the item off the list.
  # So the rule isn't depth, it's revisiting — within one top-level propagation
  # each endpoint gets acted on ONCE. event -> chore -> item is three distinct
  # endpoints and runs to the end; item -> chore -> item revisits the item and
  # stops there.
  #
  # DEPTH_CAP is a backstop for a shape nobody predicted, not the mechanism.
  module Guard
    module_function

    KEY       = :record_links_visited
    DEPTH_KEY = :record_links_depth
    DEPTH_CAP = 6

    # Runs the block with `endpoint` marked as visited, and unwinds cleanly
    # whether it returns or raises. Returns nil without running when the
    # endpoint has already been handled in this propagation.
    def visiting(endpoint)
      visited = Thread.current[KEY]
      top     = visited.nil?
      visited ||= Set.new
      depth   = Thread.current[DEPTH_KEY].to_i

      return nil if visited.include?(endpoint) || depth >= DEPTH_CAP

      Thread.current[KEY]       = visited << endpoint
      Thread.current[DEPTH_KEY] = depth + 1
      begin
        yield
      ensure
        Thread.current[DEPTH_KEY] = depth
        # Only the outermost frame clears the set. An inner frame clearing it
        # would let the cascade revisit everything it just did, which is the
        # bug this exists to prevent.
        Thread.current[KEY] = nil if top
      end
    end

    def visited?(endpoint)
      Thread.current[KEY].to_a.include?(endpoint)
    end

    # For specs and for anything that needs a genuinely clean slate.
    def reset!
      Thread.current[KEY] = nil
      Thread.current[DEPTH_KEY] = nil
    end
  end
end
