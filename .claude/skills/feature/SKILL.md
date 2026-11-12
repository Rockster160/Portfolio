---
name: feature
description: Hand a change worked out in this conversation to a Feature Builder on the Mini, which builds it on its own branch and opens a PR, the same as `/feature add` in Byte. For the Portfolio Questions session, not for a Feature Builder.
argument-hint: "[what to build]"
---

Start a Feature Builder for the change this conversation has been about, or for
`$ARGUMENTS` when it names one. The builder is a fresh Claude session with none
of this conversation: the brief you write is everything it knows.

If this session has `BYTE_BUILD_ID` set, it is a Feature Builder itself: say so
and stop.

## 1. Write the brief

Write it to `tmp/feature_brief.md`. Give it everything this conversation has
already settled, so the builder doesn't ask it again:

- **What and why**: the change and what it's for, in a few sentences.
- **How it should behave**: from the point of view of the person using it.
- **What we found**: the code it touches, as `path:line`, and how it works
  today. Only what was actually read here: the builder reads the code itself.
- **Decided**: every choice already made, and the ones that were ruled out.
- **Plan**: the steps, when there is one. Leave the section out when there
  isn't, and the builder works one out.
- **Open**: what is still undecided, which the builder should ask about.

When the plan is complete and nothing is open, end the brief with "Nothing is
left to decide: build it." The builder then goes straight to its ticket. Never
invent answers to fill **Open**: a builder that asks is better than one that
builds a guess.

Pick a title of two to six words naming what is being built. It is the build's
name in Byte, in the Claude app and on its branch.

## 2. Start it

```bash
bin/feature-build --title "<title>" --file tmp/feature_brief.md
```

## 3. Reply

Say the build has started, with its title, and that its link, its questions and
its PR arrive in the primary Buddy thread. Keep it to two lines. If the script
failed, say what it printed.
