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

## Excluding: `-`, `!`, `NOT`

A term with `-` (or `!`) in front, or a bare `NOT` before it, EXCLUDES: the listener only fires on an event that term does **not** match. Any term can be excluded - a key, a nested path, a regex, a function.

```
travel:action::departed -departed::Home              leaving anywhere but Home
chore_completion:action::completed -chore_name::Dishes   any chore except the dishes
item:action::added NOT list:name::Groceries         added to any list but Groceries
travel:action::arrived -near(40.4804 -111.9982 550m)   arriving anywhere not within 550m of that point
```

An excluded key the payload doesn't carry is excluded trivially: `-departed::Home` fires on an event with no `departed` at all. Pin the action (or another key) alongside it so the listener still means one kind of event.

Inside a term, `key:!value` and `key::!value` are the per-value forms - "has this key, and its value isn't that". Prefer the leading `-`: it reads the way it's meant and doesn't require the key.

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

## One colon contains, two colons are exact

`:` before a value is a **substring** test. `::` is **equality**.

```
item:list:name:Claude        fires on "Claude" AND "Claude Notes"
item:list:name::Claude       fires on "Claude" only
event:action::added          exactly "added"
```

Reach for `::` whenever you know the whole value, which is most of the time.

## Reaching nested keys

Payloads are nested. Keep adding segments to walk down, **separated by colons**:

```
item:list:name:Groceries     matches { list: { name: "Groceries" } }
item:list:id:7               matches { list: { id: 7 } }
item:section:name:Ocs-Backend  matches { section: { name: "Ocs-Backend" } }
```

### Dots are not separators

A payload field list - what `read_listener_guide` returns, what `Buddy::TriggerShapes` records - is written in dot notation internally, because that is how a flattened path is stored. **A listener is not.** Copying a field path verbatim produces a single key by that name:

```
item:list.name::Claude       ONE key called "list.name". Matches nothing, ever.
item:list:name::Claude       right
```

The guide renders colons for exactly this reason, and a dotted key is refused when the watch is saved. If you are reading a path from anywhere else, translate the dots.

**A segment that isn't in the payload silently never matches.** It doesn't error and it doesn't warn - `ListenerMatch` can only tell you a listener PARSES, never that its keys exist - so the watch saves cleanly and then sits there forever. `item:sparkle:yes` is a perfectly valid listener that can never fire. This is the single most common way a watch fails, so check the key path against a real payload rather than assuming a field you can see in the UI is in the trigger.

## Terms do not have to start at the scope

Only the FIRST term sets the scope. Every term after it is matched against the payload at any depth, so the scope prefix is optional and usually noise:

```
email:from:venmo subject:/Chelsea Haven paid you/     subject is not email:subject
event:add name::Game                                  name is not event:name
item:action::added list:name::Claude                   both fine
```

Repeating the scope is equally correct (`item:list:name::Claude`) and is worth it when a bare key would be ambiguous - an `item` payload has its own `id` and a `list:id` underneath it, and `id::379` could take either.

### Open terms

A term with no key at all matches a value anywhere in the payload:

```
item:Milk                    any field CONTAINING "Milk" (one colon, so substring)
Milk                         any field or key EQUAL to "Milk" (bare, so exact)
```

Both are legitimate and both are loose. A bare word is the widest thing you can write and it will fire on events you did not picture, so use one only when the word itself is the whole condition.

## Regex

Wrap in slashes. Full Ruby regex, including anchors and alternation:

```
item:action:/^(added|removed)$/
chore_completion:chore_name:/^8oz Water$/
```

Captures from the first matching term are available to a Jil task's code. A Buddy watch ignores them.

## Functions

A term written `name(args)` computes its answer instead of comparing text. Put a key path in front to point it at part of the payload (`phone:near(...)`); with none it reads the payload's top level. A function that can't answer from the payload - no coordinates, say - never matches, excluded or not: "can't tell" is not "somewhere else".

| Function | Matches when | Example |
|---|---|---|
| `near(lat lng radius)` | the payload's `lat`/`lng` are within `radius` of that point. Metres by default, or `km`/`mi`; left off, 165m (a building and its lot) | `travel:action::arrived near(40.5308 -112.0156 200m)` |

Coordinates beat a place name: a place gets renamed, two contacts share one address, and the phone reports the town. Every arrive/depart watch Buddy sets is one of these.

## ANY

Matches when the field equals any one of the listed values:

```
item:name:ANY(Milk Eggs Bread)
```

## Writing one well

1. **Start from a real payload.** Look at existing tasks on the same scope (`read_listener_guide` returns them) and copy the key paths they use. Guessing at a key name produces a listener that parses fine and never fires. A path from a field list is separated by dots - write it with colons.
2. **Narrow with `action` first.** Most scopes carry one, and "added" versus "removed" is usually the difference between what they asked for and its opposite.
3. **Anchor names that could be prefixes.** See the substring section above.
4. **Prefer an id over a name** whenever you have the id, both for precision and because a rename won't break it.
5. **One scope per listener.** `item:... email:...` can never match, because an event only ever belongs to one scope.

## Scopes are open-ended

The table below is the app's own scopes. It is **not** the whole list, and treating it as one is the single most expensive mistake you can make here.

`/jil/webhook` and `/jil/trigger/:trigger` take the scope straight off the request, so anything that can reach the app names its own. On this install that means Home Assistant - every sensor, button, camera and doorbell in the house arrives as a Jil trigger under a scope no app code declares:

| Scope | Fires when | Useful keys |
|---|---|---|
| `hass-sensor` | a house sensor or camera reports | `detected` (bool), `location` (`Doorbell`, `Driveway`, `Backyard`, `Storage`), `subject` (`person`/`pet`/`vehicle`), `device_name`, `type`, `rang`, `battery` |
| `hass-button` | a physical button is pressed | `device_name`, `type` (`single`/`double`/`hold`), `battery` |
| `hass-trigger`, `hass-alert`, `hass-update`, `hass-power`, `hass-toggle` | other Home Assistant events | varies - read a real listener |

Those names are examples, not a second fixed list. **The authoritative answer to "does this fire here?" is whether a real task listens to it**, which is exactly what `read_listener_guide` returns: `scopes` is every scope with something already listening, and `about` searches those automations by what they're for. A doorbell is not findable by guessing the word `hass-sensor`; it is findable by searching "doorbell".

So: a physical thing in the house - a door, a camera, a button, a printer, the car - is presumed watchable until a search comes back empty.

## App scopes

These fire per user, carrying that user's own data.

| Scope | Fires when | Useful keys |
|---|---|---|
| `item` | a list item is added or removed | `action` (`added`/`removed`), `name`, `list:id`, `list:name`, `section:id`, `section:name` (null when the item isn't in one) |
| `list` | a list itself changes | `action`, `id`, `name` |
| `section` | a list section changes | `action`, `name` |
| `chore_completion` | a chore is marked done or undone | `action`, `chore_name` |
| `chore` | a chore is created or edited | `action`, `name` |
| `chore_withdrawal` | pebbles are withdrawn | `action`, `amount_pebbles`, `note` |
| `chore_transfer` | pebbles move between people | `action`, `amount_pebbles` |
| `event` | an ActionEvent is logged, edited, or deleted | `action`, `name` |
| `deploy` | a deploy finishes, success or failure (Buddy reads it off the deploy's monitor broadcast) | varies by emitter; `sha`, `message`, `author` once the commit is known |
| `delivery` | a package is added, changed, arrives, or slips | `action` (`created`/`updated`/`delivered`/`delayed`), `name`, `carrier` (`amazon`/`ups`/`usps`/`fedex`/`manual`), `tracking_number`, `delivery_date`, `previous_date` (on `delayed` only), `delivered`, `amount`, `order_id`, `item_id`, `url` |
| `agenda_item` | a calendar item is created or changed | `action` (`created`/`updated`), `agenda_id`, `name` |
| `agenda_event` | an event reaches its START or END time. The start only fires while the item is still INCOMPLETE, so "when X is due and not done yet" needs no condition of its own | `action` (`started`/`ended`), `name`, `agenda_name`, `start_at`, `end_at`, `location` |
| `agenda_schedule` | a recurring schedule changes | `action` |
| `prompt` | an app prompt is created or answered | `status`, `params:source` |
| `email` | an email arrives | `from`, `subject`, `body` |
| `sms` | a text arrives | `from`, `body` |
| `task` | a Jil task runs | `name` |
| `agenda_sync` | a Google calendar sync completes | `action`, counts |
| `tesla` | car state changes | varies |
| `tesla_parked`, `tesla_charge`, `tesla_drive_start`, `tesla_drive_stop`, `tesla_shift`, `tesla_trip_started`, `tesla_trip_updated`, `tesla_trip_ended` | specific car events | varies |
| `trytravel` | anything reports a travel leg — the phone's Home geofence, the car's Bluetooth away from home, or the car crossing the home boundary | `action` (`departed`/`arrived`), `location`, `lat`, `lng`, `coord`, `from`, `source` (`phone`/`tesla`), `timestamp`, plus `departed`/`arrived` set to the place name for `travel:arrive:home`-style matching. A report is believed unless it is the Bluetooth radio reporting from home, where it reaches into the garage and pairs with a car somebody else is taking — recognised by the words `depart`/`arrive`, or by an explicit `via:"bluetooth"` |
| `travel` | a leg the PHONE saw, announced once per leg by task 54 | same keys as `trytravel`. The car never announces: a `departed` ActionEvent carrying only a `tesla` key is the car leaving without its owner |
| `monitor` | a dashboard channel updates | `channel` |
| `websocket` | a websocket message arrives | varies |
| `jarvis_subscribed` | the Jarvis channel connects | - |
| `bowling` | a bowling set is recorded | `league` |
| `climbing` | a climb is logged | varies |
| `startup` | the app boots | - |
| `tell` | something is said to Jarvis | `words` (the command with any time phrase removed), `full`, `timestamp`, `has_time` |
| `schedule` | a Jil schedule is created or changed | `schedule_id`, `action` |
| `relay` | another household member's task sends data over | whatever they put in it, plus `from` (their username) |

The table is a map, not a contract - the authoritative answer for any scope is what the user's existing tasks listen to. Read those before writing something new on a scope you haven't seen a real example of.

## Worked example: somebody at the front door

They ask to be told when someone rings the bell or is seen out front. Nothing above mentions a doorbell, and no scope name suggests one. Searching `about: "doorbell"` turns up their real automations:

```
hass-sensor:location:doorbell type:rang rang:true   sends a push when the doorbell sensor reports a ring
hass-sensor:location                                records camera detections (pet, person, vehicle, motion) per location
hass-button:device_name::"DoorbellButton1" type::single
```

The first is the ring itself, and it can be used as-is. For "seen out front", the second shows the keys the camera payload carries, so the watch is built from those:

```
hass-sensor:location:/^Doorbell$/ subject:person detected:true
```

`location` is anchored because `Doorbell` and `Driveway` are separate cameras and a bare substring would be loose; `detected:true` is there because the same scope also fires when a detection clears.
