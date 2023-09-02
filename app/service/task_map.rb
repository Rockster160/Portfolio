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
  TYPES = [
    :any,
    :str,
    # :text, acts like str, but allows more text to be entered
    :bool,
    :num,
    :duration,
    :date,
    :hash,
    :keyval,
    :array,
    :var,
    :task
  ]
  TASKS = {
    raw: {
      bool:       [
        { return: :bool },
        { block: :bool },
        # { bool: :value },
      ],
      str:       [
        { return: :str },
        { block: :str },
        # { str: :value },
      ],
      # text:      [
        # { return: :str },
        # This should allow a multi-line text input field, but still act as a string otherwise
      # ],
      num:       [
        { return: :num },
        { block: :num },
        # { num: :value },
      ],
      keyval:     [
        { return: :keyval },
        { block: :str },
        { block: :str },
      ],
      hash:       [
        { return: :hash },
        :content, # Maybe this content can only have 1 type (key/vals)
        # { content: { only: :keyval } }
        # { content: { only: [:keyval, :str] } }
      ],
      array:        [
        { return: :array },
        # Maybe arrays/hashes DO have a type?
        :content, # Maybe this content can only have 1 type (no mixed types in an array)
      ],
      # date:         [
      #   { return: :date },
      #   { block: :date },
      #   { num: :year, default: :current }, # (current is run time, not write time)
      #   { num: :month, default: :current },
      #   { num: :day, default: :current },
      #   { num: :hour, default: :current },
      #   { num: :minute, default: :current },
      #   { num: :second, default: :current },
      # ],
      # Vars exist only during the current running task
      get_var:      [
        { return: :any },
        { block: :str, name: :name },
      ],
      set_var:      [
        { return: :any },
        { block: :str, name: :name },
        :value,
        { block: :any },
      ],
      # Cache is permanent across all tasks
      get_cache:    [
        { return: :any },
        { block: :str, name: :name },
      ],
      set_cache:    [
        { return: :bool },
        { block: :str, name: :name },
        :value,
        { block: :any, name: :value },
      ],
    },
    logic: {
      if:         [
        { return: :any }, # implicitly returns last val
        :IF,
        :content,
        # Implicit- last block in content is used to eval the if
        :DO,
        :content,
        :ELSE,
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
        :NOT,
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
        { return: :num, description: "Current index of loop" },
        "Current Index",
      ],
      key:        [
        { return: :str, description: "Current key of loop" },
        "Current Key",
      ],
      object:     [
        { return: :any, description: "Current object of loop" },
        "Current Value"
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
        { return: :bool },
        { block: :str },
        { block: :str }, # Should regex be an object, or just a text entry?
        # { multiple: [:g, :i, :u, :m], name: :flags }
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
    math: {
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
        [:abs, :sqrt, :square, :cubed, :log10, :"e^"],
        { block: :num },
      ],
      advanced_ops:   [
        { return: :num },
        { block: :num },
        [:n_root, :log, :pow],
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
      cast:           [
        { return: :array },
        { block: :any },
      ],
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
      join:        [
        { return: :str },
        { block: :str, label: "Join with" },
        { block: :array },
      ],
      sum:        [
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
      includes:    [
        { return: :bool },
        { block: :array },
        { block: :any },
      ],
      # sort:        [ # - Fail for incompatible types
      #   { return: :array },
      #   { block: :array },
      #   [:asc, :desc, :random]
      # ],
      # sort_by:     [
      #   { return: :array },
      #   { block: :array },
      #   :content, # last value from content is used to sort asc
      # ],
      find:        [
        { return: :any, description: "First truthy value from array" },
        { block: :array },
        :content,
      ],
      any?:        [
        { return: :bool, description: "Bool of any truthy values in array." },
        { block: :array },
      ],
      all?:        [
        { return: :bool, description: "Bool of all truthy values in array." },
        { block: :array },
      ],
      none?:        [
        { return: :bool, description: "Bool of all falsy values in array." },
        { block: :array },
      ],
      # merge:       [
      #   { return: :array },
      #   { block: :array },
      #   { block: :array },
      # ],
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
      cast:           [
        { return: :hash },
        { block: :any },
      ],
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
      now: [
        { return: :date },
        :NOW
      ],
      # cast: [
      #   { return: :date },
      #   { block: :any },
      # ],
      round: [
        { return: :date },
        { block: :date },
        :TO,
        [:beginning, :end],
        :OF,
        [:minute, :hour, :day, :week, :month, :year],
      ],
      adjust: [
        { return: :date },
        { block: :date },
        [:+, :-],
        { block: :duration },
      ],
      # format_str: [
      #   { return: :str },
      #   { block: :date },
      #   { block: :str, name: :format },
      # ],
      # format: [
      #   { return: :str },
      #   { block: :date },
      #   [:iso8601], # Other standard formats?
      # ],
      duration: [
        { return: :duration },
        { block: :num },
        # [:seconds, :minutes, :hours, :days, :weeks, :months, :years],
        # block: :select allows dynamically selecting the value
        { block: :select, values: [:seconds, :minutes, :hours, :days, :weeks, :months, :years] },
      ],
      piece: [
        { return: :num },
        { block: :date },
        { block: :select, values: [:second, :minute, :hour, :day, :week, :month, :year] },
      ],
    },
    lists: {
      # create? | destroy | all -- lists, not items?
      # TODO: Support ordering?
      # TODO: Support Notes?
      # TODO: Support Category?
      add: [
        { return: :bool },
        { block: :str, label: :list_name },
        { block: :str, label: :item_name },
        # { block: :str, name: :category, optional: true },
      ],
      edit: [
        { return: :bool },
        { block: :str, name: :list_name },
        { block: :str, name: :old_item_name },
        { block: :str, name: :new_item_name },
        # { block: :str, name: :new_category, optional: true },
      ],
      remove: [
        { return: :bool },
        { block: :str, name: :list_name, label: "List Name" },
        { block: :str, name: :item_name, label: "Item Name" },
      ],
      get: [
        { return: :hash }, # list.serialize
        { block: :str, name: :list_name },
      ],
    },
    action_events: {
      get: [
        { return: :array },
        { block: :str, label: :Search },
        { block: :num, label: :Limit },
        { block: :date, label: :Since },
      ],
      add: [
        { return: :bool },
        { block: :str, label: :Name },
        { block: :str, label: :Notes, optional: true },
        { block: :date, label: "Date (Now)", optional: true },
      ],
      # remove
    },
    temporary: {
      distance: [
        { return: :str },
        :Address,
        { block: :str }
      ]
    },
    task: {
      input_data: [
        { return: :hash },
        "Task Input Data"
      ],
      print:      [
        { return: :str },
        { block: :str, name: :message },
      ],
      comment:    [
        { return: :str },
        { block: :text },
      ],
      command:    [
        { return: :str },
        { block: :str, name: :message },
      ],
      exit:       [ # Stop current task entirely - successfully
        { return: :any },
        { block: :any, optional: true, name: :reason },
      ],
      # fail:       [ # Stop current task entirely - as a failure
      #   { return: :any },
      #   { block: :any, optional: true, name: :reason },
      # ],
      run:        [
        { return: :any },
        "Task Name",
        { block: :str, name: :task_name },
        "When to run (Optional)",
        { block: :date, optional: true },
      ],
      # find:       [
      #   { return: :task },
      #   { block: :str, name: :task_id },
      # ],
      schedule: [
        { return: :str }, # jid of the task
        "Jarvis Command:",
        { block: :str, name: :cmd },
        "When to run:",
        { block: :date },
      ],
      # Inject/run JS on page + web scraping
      # request: [
      #   { return: :hash },
      #   [:GET, :POST, :PATCH, :PUT, :DELETE],
      #   { block: :str, name: :url },
      #   { block: :str, name: :body, optional: true },
      #   { block: :hash, name: :params, optional: true },
      #   { block: :hash, name: :headers, optional: true },
      # ],
      # Send email from Jarvis - Admin only? - Or just require some kind of email setup/permissions
      # email: [
      #   { block: :str, name: :to }, # Allow multiple?
      #   { block: :str, name: :from },
      #   { block: :str, name: :subject },
      #   { block: :str, name: :body }, # Allow html
      # ],
      # sms: [
      #   { block: :str, name: :to }, # Allow multiple?
      #   { block: :str, name: :from }, # Requires Twilio auth/set up
      #   { block: :str, name: :body }, # maybe allow images eventually?
      # ],
      ws: [
        { return: :num },
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
