return

# IF
{
  type: :if,
  condition: BLOCK,
  do: [BLOCK],
  else: [BLOCK]
}

# AND/OR
{
  type: :and, # and|or
  args: [BLOCK] # Any number
}

# COMPARE
{
  type: :compare,
  sign: "==", # == != < <= > >=
  args: [BLOCK] # Can only be 2
}

# NOT
{
  type: :not,
  arg: BLOCK
}

# VALUE
{
  type: :bool, # bool|string|int|float
  value: true # true|false
}

# VAR
{
  type: :get_var,
  name: "anything"
}
{
  type: :set_var,
  name: "anything", # user inputted string
  value: BLOCK
}

# LOOP
{
  type: :loop,
  times: 10, # integer
  do: [BLOCK]
}

{
  type: :each, # each|map
  do: [BLOCK]
}

# Special values available within a loop
{ type: :index }
{ type: :object }

# WHILE
{
  type: :while,
  condition: BLOCK,
  do: [BLOCK]
}

# BREAK
{ type: :break } # Exits a loop

# NEXT
{ type: :next } # Skips the rest of current loop iteration

# EXIT -- Skips the rest of the task
{
  type: :exit,
  reason: BLOCK # optional
}

# ============================================ MATH ================================================

# OPERATION
{
  type: :operation,
  op: "+", # + - * / %
  args: [BLOCK] # Any number, iterated through in order
}

# ADV OPS
{
  type: :adv_ops,
  op: "abs", # abs, sqrt
  value: NUM
}
# op: "rt", # rt abs log10 e^ 10^
# base: INT,
# value: NUM,

# MATCH CHECK -- name?
{
  type: :math_check,
  op: "even", # even odd prime whole positive negative divisblebyX
  value: NUM
}

# RANDOM
{ type: :random } # 0-1 with 10dec

# ROUND
{
  type: :round,
  value: NUM,
}

# ============================================ TEXT ================================================

{
  type: :match,
  value: RX|STR
}

{
  type: :split,
  value: RX|STR
}

# =========================================== Jarvis ===============================================

{
  type: :say,
  message: STR
}

#   Text:
#     √ String
#     Match? # Able to test regexp matching -- Belongs in logic?
#     Split? # Based on regex? -- Would need some way to set to an array/enumerator
#     Format # lower, upper, snake?, camel?
#     Replace # Use regexp
#     Print?
#     Prompt? (with...)
#     Base64 # / Other encodings/decodings?
#   ToLevel?:
#     Comment # Should be able to leave comments -- Does not count as iteration
#     √ Exit # Do not execute the remainder of the task
#     Fail # Raise an error / trigger a callback to the "failed_task" action - Do not execute rest
#     Schedule # trigger a job to run later -- Should also return a JID that can be stored in cache
#     Get # take from cache
#     SSH # Run a set of SSH commands...?
#     Request # Web Request - return in json format { status, body, etc... }
#     Broadcast # Send a WS -- Could use this to trigger events to Dashboard so that everything is managed back end
#   Date/Time:
#     Adjust # Add minutes/hours/seconds
#     Format # Convert to text as format
#     year/month/wday/day/hour/min/sec
#   Array:
#     Prepend/Append
#     Join # -- Becomes string
#     Get/Del at index
#     √ Iterate / Map
#     Count
#   Dictionary:
#     Set key
#     Del key
#     Get key
#     Iterate / Map
#     Count
#   Variables:
#     √ List of vars -- including var type
#   Notify:
#     SMS
#     Email
#     Notification
#   Functions:
#     fn # Defines a function that runs a block of code, similar to an `if` but returns the final value and is reusable
#     # Able to define/import functions somewhere?
#     # A function can take a number of inputs and give an output
