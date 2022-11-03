class TaskMap
  # Error state from validations
  # Error state when attempting to use a magic variable that doesn't exist (yet)
  # Should do pre-validations in JS (Make sure blocks have required vals)
  # :block becomes a drop down with available values
  #   * Default selected (when added to page) is the previous block with matching type
  #   * Dynamically populate block_ids that have the matching type
  #   * Maybe colorize block names? Or randomly generate human tokens "blue horse", "sticky jacket"...
  # :content means it should have an open/close where blocks can be placed inside - nestable
  # Other values that are not blocks:
  #   return: the type the block returns. If empty, there is no return state
  #   Sym/str - Just show as text in the block (aesthetic)
  #   Array - Dropdown of the values provided
  #   Hash -
  #     text - adds a text input - value is the placeholder/label
  #     num - adds a number input - value is the placeholder/label
  #     bool - adds a toggle - value is label
  #     multiple - dropdown of checkboxes, can select multiple
  TASKS = {
    raw: {
      bool:       [
        { return: :bool },
        { bool: :value },
      ],
      str:       [
        { return: :str },
        { str: :value },
      ],
      num:       [
        { return: :num },
        { num: :value },
      ],
      hash:       [
        { return: :hash },
        # How to do this?
        # Maybe just fields, and as you enter one a new one appears?
        # Also needs draggable/reorder?
        # [[ str(key) : :block]] :block OR :text?? Or other types?
      ],
      array:        [
        { return: :array },
        # How to do this?
        # Maybe just fields, and as you enter one a new one appears?
        # Also needs draggable/reorder?
        # :block OR :text??
      ],
      duration:     [
        { return: :duration },
        { block: :num, name: :amount },
        [:seconds, :minutes, :hours, :days, :weeks, :months, :years],
      ],
      date:         [
        { return: :date },
        { num: :year, default: :current }, # (current is run time, not write time)
        { num: :month, default: :current },
        { num: :day, default: :current },
        { num: :hour, default: :current },
        { num: :minute, default: :current },
        { num: :second, default: :current },
      ],
      # Vars exist only during the current running task
      # Get returns the var itself. Treated like the object, but changes save to the var
      # `var` should be treated like `any` unless it has been cast
      get_var:      [
        { return: :var },
        { block: :str, name: :name },
      ],
      # Clone returns the object the variable has, modifying this does NOT change the var
      clone_var:    [
        { return: :any },
        { block: :str, name: :name },
      ],
      set_var:      [
        { return: :var },
        { block: :str, name: :name },
        :value,
        { block: :any },
      ],
      # Cache is permanent across all tasks - should cache be within a transaction?
      # For example, if task fails, should changes to the cache during the task undo?
      # Cache needs to be saved - it does not do so automatically
      get_cache:    [
        { return: :any },
        { block: :str, name: :name },
      ],
      set_cache:    [
        { return: :any },
        { block: :str, name: :name },
        :value,
        { block: :any, name: :value },
      ],
    },
    logic: {
      if:         [
        { return: :any }, # implicitly returns last val
        :IF,
        { block: :any },
        # Only allow a single block for now so we don't have to deal with logic yet
        # Logic can come from other blocks. Maybe later we can do AND|OR inside of the if.
        :content,
        :else,
        # Eventually support removing the else
        # Eventually support having multiple if/else
        :content,
      ],
      and:        [
        { return: :any }, # implicitly returns last val
        { block: :any },
        :AND,
        { block: :any },
      ],
      or:        [
        { return: :any }, # implicitly returns first truthy val
        { block: :any },
        :OR,
        { block: :any },
      ],
      eq:        [
        { return: :bool },
        { block: :any },
        :==,
        { block: :any },
      ],
      not:       [
        { return: :bool },
        :!,
        { block: :any },
      ],
      times:      [
        { return: :num }, # (number of times the loop ran)
        { block: :num },
        :content,
      ],
      # infinite loop until break
      loop:       [
        { return: :num }, # (number of times the loop ran)
        :content,
        # Validates: error if no break/exit
      ],
      while:      [
        { return: :num }, # (number of times the loop ran)
        :content, # Loop plays again if this is true
        # Validates: error if empty
      ],
      index:      [
        { return: :num, description: "Current index of loop" }
      ],
      key:        [
        { return: :str, description: "Current key of loop" }
      ],
      object:     [
        { return: :any, description: "Current object of loop" }
      ],
      next:       [
        { return: :any, description: "Skip to next iteration of current loop" },
        { block: :any, optional: true },
      ],
      break:      [
        { return: :any, description: "Stop current loop completely" },
        { block: :any, optional: true },
      ],
    },
    text: {
      cast: [
        { return: :str },
        { block: :any },
      ],
      match:      [
        { return: :array, description: "Returns match groups found by regex" },
        { block: :str },
        { str: :regex }, # Should regex be an object, or just a text entry?
        { multiple: [:g, :i, :u, :m], name: :flags }
      ],
      split:      [
        { return: :array },
        { block: :str },
        { block: :str, name: :split_by, optional: true }, # Empty means split by char
      ],
      format: [
        { return: :str },
        { block: :str },
        [:lower, :upper, :capital, :pascal, :title, :snake, :camel, :base64]
      ],
      replace: [
        { return: :str },
        { block: :str, name: :value },
        { block: :str, name: :replace, optional: true }, # If not present, replace with empty/delete
        { str: :regex }, # Should regex be an object, or just a text entry?
        { multiple: :flags, checkboxes: [:g, :i, :u, :m] }
      ],
    },
    numbers: {
      cast:           [
        { return: :num },
        { block: :any },
      ],
      compare:        [
        { return: :bool },
        { block: :num },
        [:==, :!=, :<, :>, :>=, :<=],
        { block: :num },
      ],
      operation:      [
        { return: :num },
        { block: :num },
        [:+, :-, :*, :/, :%],
        { block: :num },
      ],
      single_op:      [
        { return: :num },
        [:abs, :sqrt, :square, :cubed, :log10, :e_up], # e_up is e to power of val
        { block: :num },
      ],
      advanced_ops:   [
        { return: :num },
        { block: :num },
        [:abs, :n_root, :abs, :log, :pow],
        { block: :num },
      ],
      advanced_value: [
        { return: :num },
        [:pi, :e, :inf]
      ],
      check:          [
        { return: :bool },
        { block: :num },
        [:even, :odd, :prime, :whole, :positive, :negative],
      ],
      random:         [
        { return: :num },
        { block: :num, name: :min, default: 0 },
        { block: :num, name: :max, default: 1 },
        { block: :num, name: :decimal_points, default: 5 },
      ],
      round:          [
        { return: :num },
        { block: :num, name: :value },
        { block: :num, name: :decimal_points, default: 0 },
      ],
    },
    array: {
      get:         [
        { return: :any, description: "Value of array at index" },
        { block: :array },
        { block: :number, name: :index, default: 0 },
      ],
      set:         [
        { return: :array },
        { block: :array },
        { block: :number, name: :index, default: 0 },
        { block: :any, name: :value },
      ],
      del:         [
        { return: :array, description: "Remove object at index of array" },
        { block: :array },
        { block: :number, name: :index, default: 0 },
      ],
      length:      [
        { return: :num },
        { block: :array },
      ],
      min:         [
        { return: :any, description: "Smallest value from array" },
        { block: :array },
      ],
      max:         [
        { return: :any, description: "Largest value from array" },
        { block: :array },
      ],
      sample:      [
        { return: :any, description: "Random object from array" },
        { block: :array },
      ],
      prepend:     [
        { return: :array },
        { block: :any },
        { block: :array },
      ],
      append:      [
        { return: :array },
        { block: :array },
        { block: :any },
      ],
      sort:        [ # - Fail for incompatible types
        { return: :array },
        { block: :array },
        [:asc, :desc, :random]
      ],
      sort_by:     [
        { return: :array },
        { block: :array },
        :content, # last value from content is used to sort asc
      ],
      find:        [
        { return: :any, description: "First truthy value from array" },
        { block: :array },
        :content,
      ],
      find_map:    [
        { return: :any, description: "First truthy return from array (the return, not the object)" },
        { block: :array },
        :content,
      ],
      merge:       [
        { return: :array },
        { block: :array },
        { block: :array },
      ],
      join:        [
        { return: :str },
        { block: :array },
        { block: :str, name: :join_by, default: ", " },
      ],
      each:        [
        { return: :num }, # number of times the loop ran
        { block: :array },
        :content,
      ],
      map:         [
        { return: :array },
        { block: :array },
        :content, # last value from content is used as new array value
      ],
    },
    hash: {
      get: [
        { return: :any },
        { block: :hash },
        { block: :str, name: :key },
      ],
      set: [
        { return: :hash },
        { block: :hash },
        { block: :str, name: :key },
        { block: :any, name: :value },
      ],
      del: [
        { return: :hash },
        { block: :hash },
        { block: :str, name: :key },
      ],
      keys: [
        { return: :array },
        { block: :hash },
      ],
      length: [
        { return: :num },
        { block: :hash },
      ],
      merge:  [
        { return: :hash },
        { block: :hash },
        { block: :hash },
      ],
      each:        [
        { return: :num }, # number of times the loop ran
        { block: :hash },
        :content,
      ],
      map:         [
        { return: :array },
        { block: :hash },
        :content, # last value from content is used as new array value
      ],
    },
    date: {
      cast: [
        { return: :date },
        { block: :any },
      ],
      adjust: [
        { return: :date },
        { block: :date },
        { block: :duration },
      ],
      format_str: [
        { return: :str },
        { block: :date },
        { block: :str, name: :format },
      ],
      format: [
        { return: :str },
        { block: :date },
        [:iso8601], # Other standard formats?
      ],
    },
    task: {
      comment:    [
        { block: :str, name: :message },
      ],
      command:    [
        { return: :str },
        { block: :str, name: :message },
      ],
      exit:       [ # Stop current task entirely - successfully
        { return: :any },
        { block: :any, optional: true, name: :reason },
      ],
      fail:       [ # Stop current task entirely - as a failure
        { return: :any },
        { block: :any, optional: true, name: :reason },
      ],
      run:        [
        { return: :any },
        { block: :task },
      ],
      find:       [
        { return: :task },
        { block: :str, name: :task_id },
      ],
      schedule: [
        { return: :str }, # jid of the task
        { block: :date },
        { block: :task },
      ],
      request: [
        { return: :hash },
        [:GET, :POST, :PATCH, :PUT, :DELETE],
        { block: :str, name: :url },
        { block: :str, name: :body, optional: true },
        { block: :hash, name: :params, optional: true },
        { block: :hash, name: :headers, optional: true },
      ],
      # Send email from Jarvis - Admin only? - Or just require some kind of email setup/permissions
      email: [
        { block: :str, name: :to }, # Allow multiple?
        { block: :str, name: :from },
        { block: :str, name: :subject },
        { block: :str, name: :body }, # Allow html
      ],
      sms: [
        { block: :str, name: :to }, # Allow multiple?
        { block: :str, name: :from }, # Requires Twilio auth/set up
        { block: :str, name: :body }, # maybe allow images eventually?
      ],
      ws: [
        { block: :str, name: :channel },
        { block: :hash, name: :data },
      ],
      # Not supported yet, but once the app exists, allow sending notifications via app?
      # notification: [
      #   { return: :bool },
      #   { block: :str }, # - channel
      #   { block: :hash }, # - data
      # ],
      # SSH - ?
    }
  }
end
