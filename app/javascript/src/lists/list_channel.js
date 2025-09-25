import consumer from "./../channels/consumer"

$(document).ready(function() {
  if ($(".ctr-lists.act-show").length == 0) { return }

  var list_id = $(".list-container").attr("data-list-id")

  reorderList = function() {
    var original_order = $(".list-items .list-item-container").map(function() { return $(this).attr("data-item-id") })
    var ordered_list = $(".list-items .list-item-container").sort(function(a, b) {
      var contentA = parseInt($(a).attr("data-sort-order"))
      if ($(a).find(".list-item-checkbox").prop("checked")) { contentA += 0.1 }
      var contentB = parseInt($(b).attr("data-sort-order"))
      if ($(b).find(".list-item-checkbox").prop("checked")) { contentB += 0.1 }

      return (contentA < contentB) ? 1 : ((contentA > contentB) ? -1 : 0)
    })
    var new_order = ordered_list.map(function() { return $(this).attr("data-item-id") })

    if (!original_order.toArray().eq(new_order.toArray())) {
      $(".list-items").html(ordered_list)
    }
  }

  function reorderBuckets() {
    // never touch .list-items top-level; only reorder inside each section
    $(".section-items").each(function() {
      let $bucket = $(this)
      let $items = $bucket.children(".list-item-container")

      let ordered = $items.sort(function(a, b) {
        let aOrder = parseInt($(a).attr("data-sort-order"))
        if ($(a).find(".list-item-checkbox").prop("checked")) aOrder += 0.1
        let bOrder = parseInt($(b).attr("data-sort-order"))
        if ($(b).find(".list-item-checkbox").prop("checked")) bOrder += 0.1
        if (aOrder < bOrder) return 1
        if (aOrder > bOrder) return -1
        return 0
      })

      // keep only items, keep section DOM intact
      ordered.each(function() { $(this).appendTo($bucket) })
    })
  }

  function parseIncoming(html) {
    // wrap so .find() can see top-level siblings
    let $wrap = $("<div>").html(html)

    // prefer a real .list-items root; else use the wrapper
    let $root = $wrap.find(".list-items").first()
    if ($root.length == 0) { $root = $wrap }

    // include descendants AND any top-level .list-item-container in $root
    let incomingItems = {}
    $root.find(".list-item-container")
        .add($root.filter(".list-item-container"))
        .each(function() {
          incomingItems[String($(this).data("itemId"))] = $(this)
        })

    // find the target bucket for an incoming item
    let targetFor = function($incomingItem) {
      let sid = $incomingItem.closest(".list-section-tab").data("sectionId")
      if (sid == null || sid === "") return $(".list-items")
      let $tab = $('.list-section-tab[data-section-id="' + sid + '"]')
      let $bucket = $tab.children(".section-items").first()
      return $bucket.length ? $bucket : $(".list-items")
    }

    return { $root, incomingItems, targetFor }
  }

  function ensureParent($el, $targetBucket) {
    if (!$el.parent().is($targetBucket)) { $el.appendTo($targetBucket) }
  }

  listWS = consumer.subscriptions.create({
    channel: "ListHtmlChannel",
    channel_id: "list_" + list_id
  }, {
    connected: function() {
      var url = $(".list-items").attr("data-update-url")
      $.post(url, {}).done(function() { $(".list-error").addClass("hidden") })
      // $.rails.refreshCSRFTokens()
    },
    disconnected: function() {
      $(".list-error").removeClass("hidden")
    },
    received: function(data) {
      let { $root: $incRoot, incomingItems, targetFor } = parseIncoming(data.list_html)
      let incIds = Object.keys(incomingItems)

      // 3a) Resolve placeholders by name (keeps the "quick add" feel)
      $(".item-placeholder").each(function() {
        let $ph = $(this)
        let name = $ph.find(".item-name").text()
        let $match = null

        $.each(incomingItems, function(_, $inc) {
          if ($inc.find(".item-name").text() == name) { $match = $inc; return false }
        })

        if ($match) {
          let $target = targetFor($match)
          ensureParent($match, $target)
          $ph.replaceWith($match)
        }
      })

      // 3b) Upsert every incoming item and move it to the correct bucket
      incIds.forEach(function(id) {
        let $inc = incomingItems[id]
        let $targetBucket = targetFor($inc)
        let $curr = $('.list-item-container[data-item-id="' + (id || "new") + '"]')

        if ($curr.length == 0) {
          // brand new item: insert in the right bucket
          ensureParent($inc, $targetBucket)
          $targetBucket.append($inc)
          return
        }

        // update existing item’s attrs/content (keep your icon + field logic)
        // icons
        ["important", "locked", "recurring"].forEach(function(cls) {
          let has = $inc.find(".list-item-config ." + cls).length > 0
          let $cfg = $curr.find(".list-item-config")
          if (has) {
            if ($cfg.find("." + cls).length == 0) { $cfg.append($("<div>", { class: cls })) }
          } else {
            $cfg.find("." + cls).remove()
          }
        })

        // category
        let newCat = $inc.find(".list-item-config .category").text() || ""
        $curr.find(".list-item-config .category").text(newCat)

        // sort order
        $curr.attr("data-sort-order", $inc.attr("data-sort-order"))

        // name (html to preserve highlights/emojis)
        $curr.find(".item-name").html($inc.find(".item-name").html())

        // checked state (skip if locked)
        if ($inc.find(".list-item-config .locked").length == 0) {
          $curr.find(".list-item-checkbox")
            .prop("checked", $inc.find(".list-item-checkbox").prop("checked"))
        }

        // move between buckets if needed
        ensureParent($curr, $targetBucket)
      })

      // 3c) Mark locally present items missing from server as checked (soft deleted)
      $(".list-item-container").each(function() {
        if ($(this).find(".list-item-config .locked").length > 0) { return }
        let id = $(this).data("itemId")
        if (id && !incIds.includes(String(id))) {
          $('.list-item-container[data-item-id="' + id + '"] input[type=checkbox]')
            .prop("checked", true)
        }
      })

      clearRemovedItems()
      setImportantItems()
      reorderBuckets() // was reorderList()
      document.dispatchEvent(new Event("lists:rebind"))
    }
  })

})
