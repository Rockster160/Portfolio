# Background processes — the strip in the corner of the hero

What Byte is doing while nobody is watching it: a line of job applications
being filled in on the Mac, an inbound email being read, anything else that
takes minutes and happens somewhere else.

Each one is a chip pinned to the **top-right** of the Buddy hero, opposite the
timers. It carries a name, a count (`Preparing 3/13`), the step it is on, a
fill along its bottom edge, and up to four **links** — the job, the queue it
came out of, the email being read. Swipe a chip away to clear it.

**Nothing in Rails does the work.** Every chip is put there by whatever is
doing it, through the endpoint below.

## The key is the whole design

A caller names its own work — `jobhunt:line`, `mail:triage:51716` — and every
write is an upsert on that name:

* a report for a key with nothing live behind it **starts** one,
* a report for a key already running is a **step** in it,
* a clear for a key with nothing behind it is a **no-op that still says ok**.

That is what makes this usable from a script that cannot tell a timeout from a
success, and from one that has just been restarted and knows only what it is
working on. A report for a key that was cleared by hand mid-run **puts the chip
back** rather than reporting into nothing for the next twenty minutes.

Keys are lowercase `[a-z0-9_:-]`, 61 characters at most. Colons nest. **No
dots and no slashes** — the key travels in a URL path, where a dot is a format
suffix.

## The endpoint

```
GET    /api/v1/background_processes         what is running now
POST   /api/v1/background_processes         start it, or step it
PATCH  /api/v1/background_processes/:key    the same thing, key in the path
DELETE /api/v1/background_processes/:key    clear it
```

Authenticate with `Authorization: Bearer <api key>` (what jobhunt already uses
for the board) or `X-Byte-Secret` (what the Mac's Byte server already uses).
A secret-authenticated caller may name a `user_id`; an API key is always its
own owner. Every response is wrapped: `{"data": {...}}`.

### Fields

| field | |
|---|---|
| `key` | **required.** The caller's own name for the work. |
| `name` | what it is, in two or three words. Shown in bold. `Preparing`, `Reading mail`. |
| `state` | `running` (default), `waiting` — it needs a person — or `failed`. |
| `detail` | the step it is on, under the name. |
| `current` / `total` | renders as `3/13`, and fills the bar. |
| `links` | up to four `{label, url}` — drawn as pills he can tap. See below. |
| `url` | the one-link shorthand. Same as `links: [{url: ...}]`. |
| `icon` | one emoji. Defaults to one for the state. |
| `source` | who is reporting: `jobhunt`, `mac`, `rails`. |

**Only what you send is written.** A report of `current` alone leaves the name,
the total and the url exactly as the first one set them, so the step-by-step
calls stay one line long.

Reporting `state: finished` is the same as a DELETE.

### Links

```json
"links": [
  { "label": "Posting", "url": "https://boards.greenhouse.io/x/jobs/1" },
  { "label": "Line",    "url": "http://localhost:8790/line" }
]
```

* They are **real anchors**, so a long-press offers to copy one and a
  middle-click opens a tab.
* An **absolute `http(s)` url, or a path on this site** (`/emails/51716`).
  Anything else is dropped — these arrive from scripts and end up in
  `window.open`, so `javascript:` has to be impossible rather than unlikely.
  A report carrying an unusable link still lands; it just lands without it.
* A link with **no label is labelled by where it goes** (`lever.co`). A row of
  pills all reading "Open" says nothing.
* **Four at most.** A fifth is a menu in the corner of a phone.
* With **exactly one**, the whole chip is a tap target for it as well. With
  several the body does nothing, because guessing one is how a tap meant for
  the queue opens a job posting instead.
* A form-encoded caller that cannot send a nested array may send the JSON as a
  string.

Links follow the same rule as every other field: a report that does not mention
them leaves the ones already there alone.

### It has to fit in the corner of a screen

The strip overlays Buddy, and the whole point of him is that he is visible. So
the size is enforced, not left to the callers:

* **`name` is cut to 20 characters, `detail` to 32** — on write, in the model,
  so every reporter is covered. A caller three repos away has no idea how wide
  the hero is, and an ellipsis through a name that was never going to fit is a
  worse answer than a name chosen to fit. Put the *identity* in the name (the
  company, what the job is) and the *state* in the detail.
* **Three chips at most.** The rest become one dim `+2 more` line — visible,
  because a strip showing three of eight and saying nothing reads as three.
  What gets cut is what sorts last: still running, nothing asked of anybody.
* **Two rows per chip**, unless there is something to choose between (more than
  one link) or the chip has stopped and is waiting to be acted on. A third row
  costs about as much height as the other two together, so a running chip with
  one link does without it and lets its whole body be the tap target.

That lands a running chip at ~39px and a parked one at ~56px, against a hero
that is 34–42vh. Two running chips is about a quarter of the corner.

### What it does on its own

* A chip nothing has been heard from for **15 minutes** dims and says
  `Stalled — <last step>`. Nothing is cleared automatically; a stuck process is
  the thing you asked to be able to see.
* A chip nothing has been heard from for **24 hours** drops off the strip. The
  row stays in the database. **`waiting` and `failed` are exempt** — both are
  states a caller deliberately set, neither will ever heartbeat again, and both
  are waiting on a person, so ageing one out would throw away the thing he was
  meant to come back to.
* Clearing says *stop showing me this*, not *stop doing that*. If the work is
  still going, its next report puts the chip back.

## Calling it from Ruby, in Rails

`BackgroundProcess.note` / `.clear` — the fail-soft pair. A chip is a nicety
and must never be a new way for a worker to die.

```ruby
BackgroundProcess.note(user: user, key: "mail:triage:#{email.id}",
  name: "Reading mail", icon: "✉️", detail: email.subject,
  links: [{ label: "Email", url: "/emails/#{email.id}" }])
...
BackgroundProcess.clear(user: user, key: "mail:triage:#{email.id}")
```

`report!` and `clear!` are the strict versions, and are what the endpoint uses.

## Calling it from jobhunt

`Jobhunt::Progress` wraps all of it, reads the API key from `Secrets`, and
fails soft:

```ruby
Progress.report("jobhunt:line", name: "Preparing", current: 3, total: 13,
  links: [{ label: "Posting", url: job["url"] }, { label: "Line", url: Progress.web_url("/line") }])
Progress.report("jobhunt:line", detail: "Fieldwire - writing the letter")
Progress.clear("jobhunt:line")

Progress.around("jobhunt:import", name: "Importing") { ...work... }  # clears however it ends
```

The line already reports itself: `Lineup.report_line!` on every start and
settle, and `Web::Tasks.step` pushes the step it names onto the same chip. See
**Say what the run is DOING** in jobhunt's `CLAUDE.md`.

## Calling it from a local Mac script

`RailsClient.background` / `.background_clear`, which use the shared secret the
watchers already hold:

```ruby
RailsClient.background(user_id: USER_ID, key: "mail:watcher:#{rowid}",
  name: "Reading mail", detail: subject)
RailsClient.background_clear(user_id: USER_ID, key: "mail:watcher:#{rowid}")
```

## What already reports

| key | who | when |
|---|---|---|
| `jobhunt:line` | `Jobhunt::Lineup` | an application in the line starts, steps and settles → then **parks as `waiting`** when the batch drains. Links: the posting (or the job's own page), `/line`, `/questions`. |
| `jobhunt:task` | `Jobhunt::Web::Tasks` | **any** long jobhunt work — looking for jobs, rewriting a letter, reading up on a company. A run that dies leaves a red chip. |
| `jobhunt:handoff` | `Jobhunt::Handoff` | the browser is sitting there waiting on an answer. Cleared from an `ensure`. |
| `jobhunt:review:<job id>` | `Jobhunt::Submitter` | an application is filled in and **not sent**. Cleared when it is. |
| `jobhunt:triage` | `Jobhunt::Watcher` | new jobs are in the queue |
| `jobhunt:watcher` | `Jobhunt::Watcher` | the alert watcher is blocked (`failed`) |
| `mail:triage:<email id>` | `Emails::JobTriage` | an email at the app domains goes to the model. Links: the message. |
| `mail:watcher:<rowid>` | the Mac's `job_mail_watcher.rb` | an email in the personal inbox goes to the model |

### It replaced jobhunt's announcements

Every one of these used to be a message in the Byte thread, and between them
they were noise: `needs_you` fired four times for one Fieldwire form in an hour
because each question asked again was another message, and the line's
`review_ready` had been switched off in config altogether — so the one thing
worth knowing, that a batch he walked away from was finished and waiting on
him, reached nowhere at all.

A chip is the right shape for all of it. It is **one** thing rewritten in place
rather than a message per event, it **stays** until he deals with it instead of
scrolling away, and it carries the links he would go looking for anyway.

The only announcement left is `:submitted` — "Applied to GitLab" — because that
one is a fact about something that happened rather than a state that is still
true.

## Two things worth knowing before you add one

**Wrap the slow part, not the whole job.** Mail triage settles nine tenths of
its volume against a list of senders, instantly and for free. The chip goes up
around the model call only — one that appears and vanishes inside a millisecond
is a flicker, not information.

**Clear it from an `ensure`.** A chip still claiming work that died is the
failure this exists to prevent, and it is the one the person cannot tell from
work still going on.
