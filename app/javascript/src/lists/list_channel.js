import consumer from "./../channels/consumer"

$(document).ready(function() {
  if ($(".ctr-lists.act-show").length == 0) { return }

  var list_id = $(".list-container").attr("data-list-id")

  function getOrder($el) {
    let v = parseInt($el.attr("data-sort-order")) || 0
    if ($el.is(".list-item-container") && $el.find(".list-item-checkbox").prop("checked")) {
      v += 0.1
    }
    return v
  }

  function sortBucket($bucket) {
    let items = $.makeArray($bucket.children(".list-item-container"))
    items.sort(function(a, b) {
      return getOrder($(b)) - getOrder($(a))
    })
    $(items).each(function() { $(this).appendTo($bucket) })
  }

  function reorderAll() {
    sortTopLevel()
    $(".section-items").each(function() {
      sortBucket($(this))
    })
  }

  function sortTopLevel() {
    let $root = $(".list-items").first()
    let kids = $.makeArray(
      $root.children(".list-item-container, .list-section-tab")
    )
    kids.sort(function(a, b) {
      return getOrder($(b)) - getOrder($(a))
    })
    $(kids).each(function() { $(this).appendTo($root) })
  }

  function upsertSections(incomingSections) {
    Object.keys(incomingSections).forEach(function(sid) {
      let $inc = incomingSections[sid]
      let $curr = $('.list-section-tab[data-section-id="' + sid + '"]')

      if ($curr.length == 0) {
        // brand new section: append whole thing to top-level
        $(".list-items").first().append($inc)
        return
      }

      // keep the existing .section-items bucket to avoid losing bindings
      let $currBucket = $curr.children(".section-items").first()
      let $incBucket = $inc.children(".section-items").first()

      // update sort order + header text/color
      $curr.attr("data-sort-order", $inc.attr("data-sort-order"))

      let incName = $inc.find(".section-header .section-name").text()
      if (incName) {
        $curr.find(".section-header .section-name").text(incName)
      }

      // optional color sync if you use a color attr/class
      let incColor = $inc.attr("data-color")
      if (incColor) { $curr.attr("data-color", incColor) }

      // ensure a bucket exists, prefer current one with its bindings
      if ($currBucket.length == 0 && $incBucket.length) {
        $curr.append($("<div>", { class: "section-items" }))
      }
    })
  }

  function parseIncoming(html) {
    let $wrap = $("<div>").html(html)
    let $root = $wrap.find(".list-items").first()
    if ($root.length == 0) { $root = $wrap }

    let incomingItems = {}
    $root.find(".list-item-container")
        .add($root.filter(".list-item-container"))
        .each(function() {
          incomingItems[String($(this).data("itemId"))] = $(this)
        })

    let incomingSections = {}
    $root.find(".list-section-tab")
        .add($root.filter(".list-section-tab"))
        .each(function() {
          incomingSections[String($(this).data("sectionId"))] = $(this)
        })

    let targetFor = function($incomingItem) {
      let sid = $incomingItem.closest(".list-section-tab").data("sectionId")
      if (sid == null || sid === "") return $(".list-items").first()
      let $tab = $('.list-section-tab[data-section-id="' + sid + '"]')
      let $bucket = $tab.children(".section-items").first()
      return $bucket.length ? $bucket : $(".list-items").first()
    }

    return { $root, incomingItems, incomingSections, targetFor }
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
      let { $root: $incRoot, incomingItems, incomingSections, targetFor } =
        parseIncoming(data.list_html)
      let incIds = Object.keys(incomingItems)

      upsertSections(incomingSections)  // ⬅️ make sure sections exist/update first

      // placeholders-by-name (unchanged)
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

      // upsert items + move to correct bucket (minor: same as yours)
      Object.keys(incomingItems).forEach(function(id) {
        let $inc = incomingItems[id]
        let $targetBucket = targetFor($inc)
        let $curr = $('.list-item-container[data-item-id="' + (id || "new") + '"]')

        if ($curr.length == 0) {
          ensureParent($inc, $targetBucket)
          $targetBucket.append($inc)
          return
        }

        ;["important", "locked", "recurring"].forEach(function(cls) {
          let has = $inc.find(".list-item-config ." + cls).length > 0
          let $cfg = $curr.find(".list-item-config")
          if (has) {
            if ($cfg.find("." + cls).length == 0) { $cfg.append($("<div>", { class: cls })) }
          } else {
            $cfg.find("." + cls).remove()
          }
        })

        let newCat = $inc.find(".list-item-config .category").text() || ""
        $curr.find(".list-item-config .category").text(newCat)

        $curr.attr("data-sort-order", $inc.attr("data-sort-order"))
        $curr.find(".item-name").html($inc.find(".item-name").html())

        if ($inc.find(".list-item-config .locked").length == 0) {
          $curr.find(".list-item-checkbox")
            .prop("checked", $inc.find(".list-item-checkbox").prop("checked"))
        }

        ensureParent($curr, $targetBucket)
      })

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
      reorderAll()
      document.dispatchEvent(new Event("lists:rebind"))
    }
  })

})
