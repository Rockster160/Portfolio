# Jil Named Args & Content Block Options Reference

## Named Content Block Options (Schema Syntax)

Content blocks in schema definitions can specify named options that appear in the editor dropdown. These create pre-configured statements when clicked.

### Syntax

Inside a `content([...])` spec, options can be:

| Syntax | Description | Creates |
|--------|-------------|---------|
| `Keyword.Item` | Standard schema method reference | `Keyword.Item()::Any` |
| `name:Type` | Named option with typed input | `Keyword.name()::Type` |
| `name:Type("default")` | Named option with default value | `Keyword.name("default")::Type` |
| `name:["a" "b" "c"]` | Named option with select dropdown | `Keyword.name()::String` |
| `name:["a" "b" "c"]("b")` | Select with default selection | `Keyword.name("b")::String` |

### Examples

```
# Schema definition for a custom function's content block:
content([rgb:String("0,0,0") for_ms:Numeric(1500) mode:["on" "off" "toggle"]])

# Mix standard and named options:
content([Keyword.Item rgb:String for_ms:Numeric])

# With allowed type restriction:
content(Keyval [Keyval.new rgb:String])
```

---

## Named Args in Custom Functions

### Calling Side (passing named args)

When calling a custom function, use a content block with named Keyword methods. Each entry has the key name as the method name and the value as the argument:

```jil
result = Custom.MyFunction({
  a1 = Keyword.rgb("0,40,150")::String
  a2 = Keyword.for_ms(1500)::Numeric
  a3 = Keyword.flash(0)::Numeric
})::Any
```

**Key points:**
- The method name (`rgb`, `for_ms`, `flash`) is the parameter key
- The argument (`"0,40,150"`, `1500`, `0`) is the parameter value
- Variable names (`a1`, `a2`, `a3`) are auto-generated and independent
- Order does not matter
- Parameters are optional -- only include the ones you need
- The same function can be called multiple times with different varnames

The content block is converted to a hash: `{ "rgb" => "0,40,150", "for_ms" => 1500, "flash" => 0 }`

### Function Side (receiving named args)

In the function task, use `Keyword.NamedArg("key")` in the `functionParams` block to extract values by key name:

```jil
Global.functionParams({
  color = Keyword.NamedArg("rgb")::String
  duration = Keyword.NamedArg("for_ms")::Numeric
  flash_ms = Keyword.NamedArg("flash")::Numeric
})::Array
```

**Key points:**
- The string argument to `NamedArg` is the key to look up from the caller's hash
- The variable name (`color`, `duration`) is what the function uses internally
- The cast type (`::String`, `::Numeric`) determines type coercion
- Missing keys get the type's zero-value (`""` for String, `0` for Numeric, `false` for Boolean)

### Mixing Positional and Named Args

You can mix `Keyword.Item` (positional) and `Keyword.NamedArg` (named) in the same `functionParams` block:

```jil
Global.functionParams({
  first_pos = Keyword.Item()::String
  named_val = Keyword.NamedArg("color")::String
})::Array
```

Positional items index into `input_data[:params]` independently of named args.

---

## Case/When Else Block

The `Global.case` statement now supports a dedicated `Keyword.Else` block instead of using the magic string `When("else", ...)`.

### New syntax

```jil
result = Global.case(val, {
  a1 = Keyword.When("apple", {
    b1 = Global.print("it's an apple")::String
  })::Any
  a2 = Keyword.When("banana", {
    b2 = Global.print("it's a banana")::String
  })::Any
  a3 = Keyword.Else({
    b3 = Global.print("unknown fruit")::String
  })::Any
})::Any
```

**Key points:**
- `Keyword.Else` takes only a content block (no match value)
- Place it anywhere in the case block -- it only runs if no `When` matches
- The old `Keyword.When("else", {...})` still works for backward compatibility
- Both `Else` and `When` appear in the editor dropdown when adding to a case block

---

## How It All Connects

```
Schema definition (schema.txt)
  content([rgb:String("0,0,0") for_ms:Numeric(1500)])
       |
       v
Frontend (arg.js)
  Parses name:Type(default) → registers Keyword.{name} method in Schema
       |
       v
Editor dropdown (index.js)
  Shows "rgb (String)", "for_ms (Numeric)" → creates Keyword.rgb("0,0,0")::String
       |
       v
Saved Jil code
  a1 = Keyword.rgb("0,40,150")::String
       |
       v
Backend execution (keyword.rb)
  Unknown lowercase methods → evalarg(line.arg) → returns value
       |
       v
Custom function call (custom.rb)
  Detects named Keyword args → builds hash → passes to function task
       |
       v
Function task (global.rb splatParams)
  Keyword.NamedArg("rgb") → looks up "rgb" in input_data hash
```
