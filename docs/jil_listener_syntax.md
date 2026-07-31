# Jil Listener Syntax

How to write a listener: the string that decides whether a trigger is the one you're waiting for. The same syntax drives every Jil task in the app and every custom Buddy watch, and both are matched by the same code (`Jil::ListenerMatch`), so anything true here is true in both places.

## The shape

```
scope:key:value
```

The part before the first colon is the **scope** - which kind of event you're listening to. Everything after it narrows which events within that scope count.

```
item                              every list-item event
item:action:added                 only additions
item:list:name:Groceries          only on the Groceries list
item:action:added item:list:name:Groceries    both, on the same event
```

Terms separated by whitespace must **all** match the same event. There is no `OR` between terms - use a regex or `ANY(...)` for that.

## Values are substrings, and this will bite you

A value matches if it appears **anywhere** in the field, case-insensitively.

| Listener | Field value | Matches? |
|---|---|---|
| `item:name:Milk` | `Milk` | yes |
| `item:name:milk` | `Milk` | yes (case-insensitive) |
| `item:name:ilk` | `Milk` | yes (substring) |
| `item:list:name:Claude` | `Claude Notes` | **yes** - probably not what you wanted |

**So a bare name is rarely precise enough.** If they said "my Claude list" and they also have a "Claude Notes" list, `item:list:name:Claude` fires on both. Anchor it with a regex when the name could be a prefix of another:

```
item:list:name:/^Claude$/
```

Prefer the id when you have one - it can't collide:

```
item:list:id:7
```

## Reaching nested keys

Payloads are nested. Keep adding segments to walk down:

```
item:list:name:Groceries     matches { list: { name: "Groceries" } }
item:list:id:7               matches { list: { id: 7 } }
```

A value with no key at all matches anywhere in the payload, which is almost always too loose:

```
item:Milk                    true if ANY field anywhere contains "Milk"
```

## Regex

Wrap in slashes. Full Ruby regex, including anchors and alternation:

```
item:action:/^(added|removed)$/
chore_completion:chore_name:/^8oz Water$/
```

Captures from the first matching term are available to a Jil task's code. A Buddy watch ignores them.

## ANY

Matches when the field equals any one of the listed values:

```
item:name:ANY(Milk Eggs Bread)
```

## Writing one well

1. **Start from a real payload.** Look at existing tasks on the same scope (`read_listener_guide` returns them) and copy the key paths they use. Guessing at a key name produces a listener that parses fine and never fires.
2. **Narrow with `action` first.** Most scopes carry one, and "added" versus "removed" is usually the difference between what they asked for and its opposite.
3. **Anchor names that could be prefixes.** See the substring section above.
4. **Prefer an id over a name** whenever you have the id, both for precision and because a rename won't break it.
5. **One scope per listener.** `item:... email:...` can never match, because an event only ever belongs to one scope.

## Scopes

These fire per user, carrying that user's own data.

| Scope | Fires when | Useful keys |
|---|---|---|
| `item` | a list item is added or removed | `action` (`added`/`removed`), `name`, `list:id`, `list:name` |
| `list` | a list itself changes | `action`, `id`, `name` |
| `section` | a list section changes | `action`, `name` |
| `chore_completion` | a chore is marked done or undone | `action`, `chore_name` |
| `chore` | a chore is created or edited | `action`, `name` |
| `chore_withdrawal` | pebbles are withdrawn | `action`, `amount_pebbles`, `note` |
| `chore_transfer` | pebbles move between people | `action`, `amount_pebbles` |
| `event` | an ActionEvent is logged, edited, or deleted | `action`, `name` |
| `agenda_item` | a calendar item is created or changed | `action`, `agenda_id`, `name` |
| `agenda_schedule` | a recurring schedule changes | `action` |
| `prompt` | an app prompt is created or answered | `status`, `params:source` |
| `email` | an email arrives | `from`, `subject`, `body` |
| `sms` | a text arrives | `from`, `body` |
| `task` | a Jil task runs | `name` |
| `agenda_sync` | a Google calendar sync completes | `action`, counts |
| `tesla` | car state changes | varies |
| `tesla_parked`, `tesla_charge`, `tesla_drive_start`, `tesla_drive_stop`, `tesla_shift`, `tesla_trip_started`, `tesla_trip_updated`, `tesla_trip_ended` | specific car events | varies |
| `monitor` | a dashboard channel updates | `channel` |
| `websocket` | a websocket message arrives | varies |
| `jarvis_subscribed` | the Jarvis channel connects | - |
| `bowling` | a bowling set is recorded | `league` |
| `climbing` | a climb is logged | varies |
| `startup` | the app boots | - |

The table is a map, not a contract - the authoritative answer for any scope is what the user's existing tasks listen to. Read those before writing something new on a scope you haven't seen a real example of.
