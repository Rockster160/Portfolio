// Builds a complete AgendaItem JSON object for the store from a minimal
// "what the user just typed" payload — the optimistic stand-in shown to
// the user while the queue drains the create POST in the background.
//
// The renderer reads from `item.presentation_attrs`, so we mirror the
// keys `AgendaItem#presentation_attrs` emits server-side. Anything we
// don't know yet (resolved travel address, server-stamped timestamps,
// schedule fingerprint) gets a safe default. When the server confirms,
// `AgendaStore.upsertItem` sees the matching `client_mutation_id` and
// swaps the temp row for the canonical one with a single in-place patch
// — no flicker, no duplicate, no DOM identity churn.
//
// Inputs:
//   minimal: {
//     id:            "temp:..." | <real id>,
//     client_mutation_id: <uuid>,
//     name, kind, color, location, notes,
//     start_at, end_at,  // epoch seconds
//     all_day,           // boolean
//     arrive_early_minutes,
//     agenda_id, agenda_name, agenda_color, agenda_source,
//   }

(function () {
  if (typeof window === "undefined") return;

  function bool(v) { return v === true || v === "true"; }

  function buildOptimisticItem(minimal) {
    const id           = String(minimal.id || "");
    const kind         = minimal.kind || "event";
    const startAt      = Number(minimal.start_at) || 0;
    const endAt        = minimal.end_at == null ? null : Number(minimal.end_at);
    const allDay       = !!minimal.all_day;
    const arriveEarly  = Number(minimal.arrive_early_minutes) || 0;
    const color        = minimal.color || minimal.agenda_color || "";
    const agendaId     = minimal.agenda_id || "";
    const agendaName   = minimal.agenda_name || "";
    const agendaColor  = minimal.agenda_color || "";
    const agendaSource = minimal.agenda_source || "";

    const presentation_attrs = {
      "item-id":               id,
      "item-url":              "", // unknown until server creates the row
      "phantom":               false,
      "recurring":             false,
      "agenda-schedule-id":    "",
      "detached":              false,
      "kind":                  kind,
      "color":                 color,
      "agenda-id":             agendaId,
      "agenda-name":           agendaName,
      "agenda-color":          agendaColor,
      "agenda-source":         agendaSource,
      "all-day":               !!allDay,
      // `end-date` mirrors `AgendaItem#presentation_attrs` which emits the
      // INCLUSIVE end date as an epoch (server does `(end_at - 1.second).to_date.to_time.to_i`).
      // For all-day, `endAt` is the exclusive next-day-midnight epoch
      // (Google convention) so we walk back to the inclusive day — without
      // this the optimistic banner spans one extra day until the server
      // response lands.
      "end-date":              allDay && endAt ? endAt - 86400 : (endAt || startAt),
      "start-at":              startAt,
      "end-at":                endAt,
      "name":                  minimal.name || "",
      "notes":                 minimal.notes || "",
      "location":              minimal.location || "",
      "resolved-address":      "",
      "arrive-early-minutes":  arriveEarly,
      "travel-minutes":        0,
      "travel-from-kind":      "",
      "travel-from":           "",
      "chain-predecessor-id":  "",
      "chain-successor-id":    "",
      "chain-prev-end-epoch":  "",
      "leave-at-epoch":        "",
      "post-travel-to":        "",
      "post-travel-minutes":   0,
      "post-arrive-at-epoch":  "",
      "trigger-expression":    "",
      "schedule":              "",
      "attendees":             "[]",
      "organizer":             "null",
      "self-response":         "",
    };

    return {
      id:                  id,
      client_mutation_id:  minimal.client_mutation_id || "",
      agenda_id:           agendaId,
      agenda_name:         agendaName,
      agenda_color:        agendaColor,
      kind:                kind,
      name:                minimal.name || "",
      notes:               minimal.notes || "",
      location:            minimal.location || "",
      color:               color,
      start_at:            startAt,
      end_at:              endAt,
      all_day:             allDay,
      arrive_early_minutes: arriveEarly,
      status:              "confirmed",
      phantom:             false,
      recurring:           false,
      detached:            false,
      crossed_out:         false,
      completed_at:        null,
      attendees:           [],
      organizer:           null,
      self_response:       "",
      editable:            true,
      metadata:            {},
      // Stamp updated_at to the wall-clock so the stale-time guard in
      // upsertItem treats a slow Monitor broadcast as older and skips
      // it. Server's real updated_at will overwrite once confirmed.
      updated_at:          Math.floor(Date.now() / 1000),
      presentation_attrs,
    };
  }

  window.AgendaOptimisticItem = { buildOptimisticItem };
})();
