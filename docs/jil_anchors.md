# Anchors

How to schedule something against a moment that **moves**.

A cron says "6am". Sunset isn't 6am — it drifts a minute a day, and the number you'd have to write down changes. An anchor is a named time you feed from a Jil task, and anything scheduled against it re-resolves whenever you feed it again.

```
Anchor.set("sun:sunset", at, "2026-08-19")     # a task writes the time
cron: sun:sunset-5m                            # a task runs 5 minutes before it
```

Nothing in Ruby knows what "sunset" means. `trash:pickup`, `school:bell`, `tide:high` work exactly the same way the moment you write one — there is no list of allowed anchors to add yourself to.

## The key

```
domain:event
```

Lowercase letters, digits and underscores on each side of the colon. It's normalized (downcased, trimmed) on save, and unique per user. That's the whole rule — `sun:sunset` and `shift_2:start` are equally valid.

An anchor exists independently of whether it currently has any times on it. That matters: a cron naming an anchor with nothing upcoming stays **valid** and starts working again the moment you feed it. Only a key that was never created is an error.

## Using one in a cron

Put the expression in a task's **Cron** field. It composes with real crons through the existing `|`, and the soonest still wins:

```
sun:sunset-5m                    5 minutes before the next sunset
sun:sunrise+30m                  half an hour after the next sunrise
trash:pickup-1h                  an hour before the bins go out
sun:sunset-5m | 0 6 * * *        whichever comes first
```

### Offsets

A sign, a number, and a unit. Units are `s`, `m`, `h`, `d`, `w`, and they chain:

```
-5m        -1h30m       -3h30m       +2d       -1w       -1w2d
```

**The unit is required.** `sun:sunset-5` is rejected rather than guessed at — five of *what* is exactly the kind of ambiguity that puts an automation an hour off.

The offset participates in resolution rather than being applied afterwards. At 20:21, with sunset at 20:24, `sun:sunset` still resolves to tonight but `sun:sunset-5m` has already gone by and rolls to tomorrow. That's what you want: "5 minutes before sunset" is a moment that has passed.

### Pinning one occurrence

Put the occurrence's identifier in brackets:

```
sun:sunset[2026-08-19]-5m        5 minutes before THAT sunset, and no other
```

Brackets rather than another colon, because the colon already separates domain from event and an identifier is usually a date — `sun:sunset:2026-08-19-5m` would leave both the third colon and the trailing `-5m` to be inferred. Delimiting ends the identifier explicitly, so it can hold **anything**: dates, spaces, slashes, even something shaped like an offset.

```
trash:pickup[week 32]            spaces are fine
sun:sunset[-5m]-1h               an identifier that looks like an offset, and a real offset
```

A pinned expression is a **one-shot**. Once that occurrence is past there is no next one and it stops resolving, so the task's next run goes blank. That's deliberate — but it means you don't want a pinned cron on a task you expect to keep firing.

### Several anchors at once

`|` already meant "whichever comes first", and anchors join it on equal footing:

```
sun:sunset-5m | trash:pickup-1h              two anchors
sun:sunset-5m | trash:pickup-1h | 0 6 * * *  two anchors and a cron
```

The soonest wins, and the task re-resolves when **either** anchor moves.

## Feeding an anchor from Jil

```
at = Date.new(2026, 8, 19, 20, 24)::Date
a = Anchor.set("sun:sunset", at, "2026-08-19")::Anchor
```

| Call | Does |
|---|---|
| `Anchor.set(key, at, id)` | Upsert a time. Creates the anchor if it's new. |
| `Anchor.set(key, at)` | Append a time with no identifier. |
| `Anchor.remove(key, id)` | Drop that one occurrence; the anchor stays. |
| `Anchor.clear(key)` | Drop every occurrence; the anchor stays. |
| `Anchor.destroy(key)` | Forget the anchor entirely. |
| `Anchor.next(expression)` | The next time, offsets and pins included. |
| `Anchor.list` | Every anchor you have. |
| `Anchor.prune(key)` | Trim history now (writes do this anyway). |
| `Anchor.trigger(expr, name, scope, data)` | Schedule a trigger against one occurrence. |
| `Anchor.untrigger(expr, name)` | Remove it again. |

### The identifier is what makes a refresh safe

Writing the **same identifier** replaces that occurrence. Writing **no identifier** appends a new one.

So a task that restates the same eight days every hour should pass the date as the identifier — it converges on eight rows instead of piling up 192 a day. Reach for the un-identified form only when each write really is a new, distinct moment.

### Feeding several days

```
day = Global.get("day")::Hash
at = day.get("sunset")::Date
id = at.format("%Y-%m-%d")::String
a = Anchor.set("sun:sunset", at, id)::Anchor
```

## Triggers, and when to use one instead

A **cron** is the right tool for "every sunset, forever" — it re-arms itself and needs nothing feeding it. `Anchor.trigger` is for one occurrence at a time: a pre-event reminder, a leave-by alert, anything you schedule in response to something rather than on repeat.

```
s = Anchor.trigger("sun:sunset-5m", "porch-lights", "porch_lights", {})::Schedule
```

That fires the `porch_lights` listener five minutes before the next sunset, with whatever data you pass reaching the task as its input. It's keyed by (occurrence, name), so calling it again for the same occurrence updates that row rather than stacking another — and different names on the same occurrence stay separate.

It refuses to schedule a moment that has already gone by, rather than creating something that fires the instant it exists.

The trigger is bound to the **occurrence**, so if that time later moves the trigger moves with it — and won't fire at the time it was originally set for. If the occurrence is deleted, the trigger goes with it.

## What happens when a time moves

Writing an occurrence re-resolves everything hanging off it, immediately:

- **Cron tasks** are re-saved, so `next_trigger_at` is recomputed from the new answer. They don't wait until their next run to notice.
- **Derived triggers** follow the specific occurrence they were bound to.

This is the reason anchors are worth a record rather than a cron string. A cron resolves once and is then a fixed stamp; an anchor keeps the question, so a forecast that shifts three minutes at 4pm moves tonight's 8:19pm task to 8:22pm without anyone re-running anything.

A trigger is bound to an **occurrence**, not to the anchor. An anchor may be hourly, daily or weekly, so there is no "near enough" window that's right for all of them — the identity is. If the occurrence is deleted, its pending triggers go with it.

Already-started triggers are left alone; their automation is underway.

## How long times are kept

Past occurrences are kept **by count, not by age** — the last 10 per anchor.

Counting rather than ageing is deliberate. A fixed window like "7 days" keeps 168 rows for an hourly anchor and loses last week's for a weekly one. Keeping the last 10 always spans 10 of that anchor's own intervals, whatever they are.

Past ones are kept at all because a **positive** offset fires after the moment: `sun:sunset+1h` is still pending an hour later, and the occurrence it's bound to has to still be there. An occurrence a pending trigger is bound to is never pruned, however old it is.

Pruning happens on write, so a feeder that runs regularly needs no cleanup task.

## When it isn't understood

Two different kinds of wrong, treated differently on purpose.

### Unreadable — blocks the save

No amount of setting things up later makes these mean anything, and a cron that can't be read resolves to nothing, which is indistinguishable from a task with no schedule. It would just quietly stop running. So the save is rejected and says why:

| You wrote | You get |
|---|---|
| `sun:sunset-5` | `couldn't read the offset … like sun:sunset-5m (units: s, m, h, d, w)` |
| `not a cron` | `couldn't read "not a cron" as a cron or an anchor` |

The check only runs when the cron actually changes, so an older task with an unreadable cron can still stamp `last_trigger_at` after a run. Otherwise it would stay pending and re-run in a loop.

### Not there yet — warns, and saves

An anchor that doesn't exist is a **warning**, not an error. Writing the task before its feeder is a perfectly reasonable order to work in, and blocking it would force everyone to build in one particular sequence:

```
school:bell doesn't exist yet. Known anchors: sun:sunset, trash:pickup
```

The task saves, the warning appears on save, and nothing else happens. If the cron names several anchors, it schedules off whichever ones *are* ready and warns about the rest — so `trash:pickup-1h | school:bell-15m` runs off pickup while bell is still hypothetical.

The moment the anchor is created and fed, the task picks it up with no edit: feeding an anchor re-resolves every cron that names it. The warning stops appearing on its own.

### Confirming it worked

The **Next run** column on the task row shows the resolved time and how far off it is. A dash means nothing resolved — either every anchor it names is still empty, or it's a placeholder waiting on one.

## The weather cache

The **Weather Refresh** task is the one fetch everything else reads. Hourly, or
on demand via the `weather-refresh` trigger, it stores the whole OpenWeather
payload in the `weather` cache and writes the `sun:sunrise` / `sun:sunset`
occurrences from that same response:

```
user_caches["weather"] = { forecast: <full onecall body>, fetched_at: <iso8601> }
```

`WeatherService` reads it before considering a fetch of its own, so Buddy's
`check_weather`, the Today briefing and anything else are quoting the same
numbers rather than three independently-timed fetches. Reading it costs nothing
and bills nobody, so unlike a live fetch it works outside production too. It's
home-only — a named place still has to be looked up — and a cache older than
three hours is ignored rather than trusted, so a feeder that has actually
stopped doesn't leave Buddy quoting yesterday.

`hourly` is deliberately NOT excluded from the request. The dashboard cell needs
per-hour icons and temps, and the point of one shared cache is that a single
fetch serves everybody.

### Reaching the dashboard

The cell doesn't fetch — it subscribes to the `weather` Monitor channel, the
same way the calendar and printer cells do:

```
Weather Refresh ──> weather cache ──> Monitor.refresh("weather")
                                             │
                                   Weather Monitor  (listener monitor:weather)
                                             │
                                   Monitor.broadcast("weather", …)
                                             │
                                      the dashboard cell
```

**Weather Monitor** is the only thing that broadcasts, and it reads the cache
rather than fetching. That matters twice: the hourly refresh nudges it after
writing, and the cell's `resync()` on connect lands there too — so a dashboard
opening at 3pm gets the 3pm forecast immediately instead of waiting for the top
of the hour, and a reconnect costs nothing.

No `refreshInterval`, and no polling: the push IS the update, and it arrives at
the top of each hour, which is exactly when hourly data changes. The api key
stayed on the server as a side effect — the browser has no reason to hold it, so
`show.html.erb` no longer ships it to the page.

## Buddy and Byte

`check_anchor` gives the assistant read access:

- `check_anchor` with a `key` — when that anchor is next, optionally shifted by an `offset`
- `check_anchor` with no key — every anchor and its next time, which is also how it discovers what exists

That's enough for "when's sunset?", "when do the bins go out?", and for reasoning that needs the time to answer something else ("do I have time for a walk before dark?"). It's a read-only tool — Buddy can't create or feed anchors, since a feeder is a task you write deliberately.

## See also

- `docs/jil_listener_syntax.md` — listeners, the other half of what makes a task fire
- `app/models/anchor.rb` — resolution, propagation and retention
- `app/service/anchor_expression.rb` — the expression grammar
