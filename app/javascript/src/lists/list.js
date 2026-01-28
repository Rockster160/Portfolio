var heldListItem, heldListItemTimer, clearListItemTimer, clearListActive;

function parseParams(str) {
  var pieces = str.split("&"),
    data = {},
    i,
    parts;
  for (i = 0; i < pieces.length; i++) {
    parts = pieces[i].split("=");
    if (parts.length < 2) {
      parts.push("");
    }
    data[decodeURIComponent(parts[0])] = decodeURIComponent(parts[1]);
  }
  return data;
}
params = parseParams(window.location.search.slice(1));

const second = 1000;
const minute = second * 60;
const hour = minute * 60;
const resetModeTimes = {
  kiosk: 30 * minute,
  clear: 3 * second,
};

function parseDuration(str, fallback = 0) {
  if (typeof str !== "string") return fallback;

  const regex = /(\d+)([hms])/g;
  let total = 0;
  let match;

  while ((match = regex.exec(str)) !== null) {
    const value = parseInt(match[1], 10);
    const unit = match[2];

    if (unit === "h") total += value * hour;
    else if (unit === "m") total += value * minute;
    else if (unit === "s") total += value * second;
  }

  return total || fallback;
}

// Check for data attributes on the list container (allows page-specific overrides)
function getListSettings() {
  const container = document.querySelector(".list-container[data-list-mode]");
  const dataMode = container?.dataset.listMode;
  const dataReset = container?.dataset.listReset;

  const mode = params.mode || dataMode || (params.clear == "1" ? "clear" : "normal");
  const reset = parseDuration(params.reset || dataReset, resetModeTimes[mode]);

  return { mode, reset };
}

// ?mode=kiosk | clear | normal
// ?reset=30s | 5m | etc.
// Or use data-list-mode and data-list-reset attributes on .list-container
let listMode, resetTime;
document.addEventListener("DOMContentLoaded", function () {
  const settings = getListSettings();
  listMode = settings.mode;
  resetTime = settings.reset;
});

$(document).on("keyup", "input.filterable", function () {
  var currentText = $(this)
    .val()
    .toLowerCase()
    .replace(/^( *)|( *)$/g, "")
    .replace(/ +/g, " ");

  if (currentText.length == 0) {
    $(".list-item-container").removeClass("hidden");
  } else {
    $(".list-item-container").each(function () {
      var option_with_category =
        $(this).find(".list-item-config .category").text() +
        " " +
        $(this).find(".item-name").text();
      var optionText = option_with_category
        .toLowerCase()
        .replace(/^( *)|( *)$/g, "")
        .replace(/ +/g, " ");
      if (optionText.indexOf(currentText) >= 0) {
        $(this).removeClass("hidden");
      } else {
        $(this).addClass("hidden");
      }
    });
  }
});

clearRemovedItems = function () {
  if (resetTime) {
    console.log("Clearing in", resetTime, "ms");
    clearTimeout(clearListItemTimer);
    clearListItemTimer = setTimeout(function () {
      $(".list-item-checkbox:checked").each(function () {
        const wrapper = $(this).closest(".list-item-container");
        if (wrapper.find(".list-item-config .locked").length > 0) {
          $(this).prop("checked", false);
        } else {
          wrapper.remove();
        }
      });
    }, resetTime);
  }
};

let __dragPos = { x: 0, y: 0 };
function __trackPointer(e) {
  let t = e.touches && e.touches[0];
  __dragPos.x = t ? t.pageX : e.pageX;
  __dragPos.y = t ? t.pageY : e.pageY;
}

function __maybeSnapToEdges($item) {
  let $root = $(".list-items");
  if ($root.length == 0) return false;

  let r = $root[0].getBoundingClientRect();
  let y = __dragPos.y - window.scrollY;
  let threshold = 24;

  if (y < r.top + threshold) {
    $item.detach().prependTo($root);
    return true;
  }
  if (y > r.bottom - threshold) {
    $item.detach().appendTo($root);
    return true;
  }
  return false;
}

function __maybeSnapIntoEmptySection($item) {
  let cx = __dragPos.x - window.scrollX;
  let cy = __dragPos.y - window.scrollY;
  let el = document.elementFromPoint(cx, cy);
  let $tab = $(el).closest(".list-section-tab");
  if ($tab.length == 0) return false;

  let $bucket = $tab.children(".section-items").first();
  if ($bucket.children(".list-item-container").length == 0) {
    $item.detach().prependTo($bucket);
    return true;
  }
  return false;
}

function buildFullOrder() {
  let out = [];
  $(".list-items")
    .children(".list-item-container, .list-section-tab")
    .each(function () {
      let $el = $(this);
      if ($el.is(".list-item-container")) {
        out.push({ type: "item", id: $el.data("itemId") });
        return;
      }
      let sid = $el.data("sectionId");
      let items = $el
        .find("> .section-items > .list-item-container")
        .map(function () {
          return { type: "item", id: $(this).data("itemId") };
        })
        .toArray();
      out.push({ type: "section", id: sid, items });
    });
  return out;
}

function debounce(fn, ms) {
  let t;
  return function () {
    clearTimeout(t);
    t = setTimeout(fn, ms);
  };
}
const persistLater = debounce(function () {
  let url = $(".list-items").data("updateUrl");
  if (!url) return;
  $.ajax({
    url,
    type: "POST",
    data: JSON.stringify({ ordered: buildFullOrder() }),
    contentType: "application/json; charset=UTF-8",
    dataType: "json",
  });
}, 60);

function initSortables() {
  $(".list-items, .section-items").each(function () {
    if ($(this).data("ui-sortable")) $(this).sortable("destroy");
  });

  let draggingSection = false;
  const CONNECT_ALL = ".section-items, .list-items";
  const CONNECT_ROOT_ONLY = ".list-items";

  function toggleEmptyHints(on) {
    if (on) {
      $(".section-items").each(function () {
        if ($(this).children(".list-item-container").length == 0) {
          $(this).addClass("__empty-target");
        }
      });
    } else {
      $(".section-items").removeClass("__empty-target");
    }
  }

  function addAnchors() {
    // root edges
    if ($(".list-items > .__root-top-anchor").length == 0) {
      $('<div class="__root-top-anchor" aria-hidden="true">').prependTo(
        ".list-items",
      );
    }
    if ($(".list-items > .__root-bottom-anchor").length == 0) {
      $('<div class="__root-bottom-anchor" aria-hidden="true">').appendTo(
        ".list-items",
      );
    }
    // between sections
    $(".list-section-tab").each(function () {
      if ($(this).next().hasClass("__after-section-anchor")) return;
      $('<div class="__after-section-anchor" aria-hidden="true">').insertAfter(
        $(this),
      );
    });
    // into section (top)
    $(".section-items").each(function () {
      if ($(this).children(".__section-top-anchor").length) return;
      $('<div class="__section-top-anchor" aria-hidden="true">').prependTo(
        $(this),
      );
    });
  }

  function removeAnchors() {
    $(
      ".__root-top-anchor, .__root-bottom-anchor, .__after-section-anchor, .__section-top-anchor",
    ).remove();
  }

  // ROOT: sections + items
  $(".list-items").sortable({
    connectWith: CONNECT_ALL,
    // include anchors as positions (not draggable—no handle inside)
    items:
      "> .list-section-tab, > .list-item-container, > .__root-top-anchor, > .__root-bottom-anchor, > .__after-section-anchor",
    handle: ".list-item-handle",
    cancel: "input,textarea,button,.list-item-field,.list-item-category-field",
    tolerance: "pointer",
    forcePlaceholderSize: true,
    placeholder: "drag-placeholder",

    start: function (e, ui) {
      draggingSection = ui.item.hasClass("list-section-tab");
      $(document).on("mousemove touchmove", __trackPointer);
      addAnchors();
      $(".list-section-tab").addClass("__pe-none"); // let hits fall to anchors/buckets
      toggleEmptyHints(true);

      if (draggingSection) {
        $(".list-items").sortable("option", "connectWith", CONNECT_ROOT_ONLY);
        $(".section-items").sortable("option", "disabled", true);
        ui.placeholder
          .addClass("drag-section-placeholder")
          .height(
            ui.item.find(".section-header").outerHeight() ||
              ui.item.outerHeight(),
          );
      } else {
        ui.placeholder.height(ui.item.outerHeight());
      }
    },

    // no detach() calls here — let Sortable place the placeholder using anchors

    update: function (evt, ui) {
      if (ui.sender) return;
      persistLater();
    },

    stop: function (e, ui) {
      $(document).off("mousemove touchmove", __trackPointer);
      $(".list-section-tab").removeClass("__pe-none");
      toggleEmptyHints(false);
      if (draggingSection) {
        $(".list-items").sortable("option", "connectWith", CONNECT_ALL);
        $(".section-items").sortable("option", "disabled", false);
      }
      draggingSection = false;
      removeAnchors();
      document.dispatchEvent(new Event("lists:persist-order"));
    },
  });

  // SECTION buckets: items only
  $(".section-items").sortable({
    connectWith: CONNECT_ALL,
    items: "> .list-item-container, > .__section-top-anchor", // anchors allowed, sections not
    handle: ".list-item-handle",
    cancel: "input,textarea,button,.list-item-field,.list-item-category-field",
    tolerance: "pointer",
    dropOnEmpty: true,
    forcePlaceholderSize: true,
    placeholder: "drag-placeholder",

    start: function (e, ui) {
      $(document).on("mousemove touchmove", __trackPointer);
      addAnchors();
      $(".list-section-tab").addClass("__pe-none");
      toggleEmptyHints(true);
      ui.placeholder.height(ui.item.outerHeight());
    },

    receive: function (e, ui) {
      // backstop: if a section somehow arrives, bounce it
      if (ui.item.hasClass("list-section-tab")) {
        $(this).sortable("cancel");
        return;
      }
      persistLater();
    },

    update: function (evt, ui) {
      if (!ui.sender) persistLater();
    },

    stop: function (e, ui) {
      $(document).off("mousemove touchmove", __trackPointer);
      $(".list-section-tab").removeClass("__pe-none");
      toggleEmptyHints(false);
      removeAnchors();
      document.dispatchEvent(new Event("lists:persist-order"));
    },
  });
}

$(document).ready(function () {
  if ($(".ctr-lists, .ctr-list_items").length == 0) {
    return;
  }

  setImportantItems = function () {
    $(".important-list-items").html("");
    $(".list-item-config .important")
      .closest(".list-item-container")
      .each(function () {
        return $(".important-list-items").append($(this).clone());
      });
  };

  $(".lists").sortable({
    handle: ".list-item-handle",
    start: function () {
      $(".list-item-container .list-item-field:not(.hidden)").blur();
    },
    update: function (evt, ui) {
      var list_order = $(this)
        .children()
        .map(function () {
          return $(this).attr("data-list-id");
        });
      var url = $(this).attr("data-reorder-url");
      var args = { list_ids: list_order.toArray() };
      $.post(url, args);
    },
  });
  initSortables();

  $(".new-list-item-form").submit(function (e) {
    e.preventDefault();
    let input = $(".new-list-item").val();

    if (input == "") {
      $(".new-list-item").val("");
      return false;
    }
    if (input == ".clear") {
      $(".new-list-item").val("");
      clearListActive = true;
      return false;
    }
    if (input == ".reload") {
      $(".new-list-item").val("");
      return window.location.reload(true);
    }
    $(window).animate({ scrollTop: window.scrollHeight }, 300);
    $.post(this.action, $(this).serialize());

    // Add a placeholder
    let template = document.getElementById("list-item-template");
    let clone = template.content.firstElementChild.cloneNode(true);
    clone.querySelector(".item-name").innerText = input;
    clone.classList.add("item-placeholder");
    $(".list-items").prepend(clone);

    $(".new-list-item").val("");
    return false;
  });

  $(document)
    .on("change", ".list-item-container .list-item-checkbox", function (evt) {
      var $itemField = $(this)
        .closest(".list-item-container")
        .find(".list-item-field");
      if (!$itemField.hasClass("hidden")) {
        $(this).prop("checked", false);
        evt.preventDefault();
        return false;
      }
      var item_id = $(this).closest("[data-item-id]").attr("data-item-id");
      if (item_id) {
        $(
          ".list-item-container[data-item-id='" +
            item_id +
            "'] input[type=checkbox]",
        ).prop("checked", this.checked);
      }
      listWS.perform("receive", {
        list_item: { id: item_id, checked: this.checked },
      });
      clearRemovedItems();
    })
    .on("change", ".list-item-options .list-item-checkbox", function (evt) {
      var args = {};
      args.id = $(this).parents(".list-item-options").attr("data-item-id");
      args[$(this).attr("name")] = this.checked;

      $.ajax({
        url: $(this).attr("data-submit-url"),
        type: "PATCH",
        data: args,
      });
    });

  $(document)
    .on("keyup", ".list-item-field, .list-item-category-field", function (evt) {
      if (evt.which == keyEvent("ENTER")) {
        $(this).blur();
      }
    })
    .on("click", ".category-btn", function (evt) {
      var evtContainer = $(evt.target).closest(".list-item-container");
      if (evtContainer) {
        evt.stopPropagation();
        if (evtContainer.hasClass("ui-sortable-helper")) {
          return;
        }
        var $itemName = evtContainer.find(".item-name");
        var $itemCategory = evtContainer.find(".list-item-config .category");
        var $itemField = evtContainer.find(".list-item-category-field");
        $itemName.addClass("hidden");
        $itemField.val($itemCategory.text());
        $itemField.removeClass("hidden");
        setTimeout(function () {
          $itemField.focus();
        }, 0);
      }
    })
    .on("blur", ".list-item-field, .list-item-category-field", function () {
      var $container = $(this).closest(".list-item-container"),
        submitUrl = $container.attr("data-item-url"),
        updatedName = $(this).val(),
        $itemName = $container.find(".item-name"),
        $itemField = $(this),
        args = {};

      if ($(this).hasClass("list-item-field")) {
        $itemName.data().raw = updatedName;
        $itemName.val(updatedName);
      } else {
        // category edit
      }

      $itemName.removeClass("hidden");
      $itemField.addClass("hidden");

      var fieldName = $(this).attr("name");
      args.list_item = {};
      args.list_item[fieldName] = updatedName;

      $.ajax({
        url: submitUrl,
        type: "PUT",
        data: args,
      });
    });

  $(document)
    .on(
      "mousedown touchstart",
      ".list-item-container[data-editable]",
      function (evt) {
        var evtContainer = $(evt.target).closest(".list-item-container");
        const isHandle = $(evt.target).closest(".list-item-handle").length > 0;
        if (!isHandle && evtContainer) {
          heldListItem = evtContainer;
          heldListItemTimer = setTimeout(function () {
            if (evtContainer.hasClass("ui-sortable-helper")) {
              return;
            }
            var $itemName = heldListItem.find(".item-name");
            var $itemField = heldListItem.find(".list-item-field");
            $itemName.addClass("hidden");
            $itemField.val($itemName.data().raw);
            $itemField.removeClass("hidden");
            $itemField.focus();
          }, 700);
        }
      },
    )
    .on("mousemove scroll", function (evt) {
      if (!heldListItem) {
        return;
      }
      if (
        heldListItem.attr("data-item-id") !=
        $(evt.target).closest(".list-item-container").attr("data-item-id")
      ) {
        heldListItem = null;
        clearTimeout(heldListItemTimer);
      }
    })
    .on("mouseup touchend", function (evt) {
      $(".list-item-field:not(.hidden)").focus();
      heldListItem = null;
      clearTimeout(heldListItemTimer);
    });

  setImportantItems();
  document.addEventListener("lists:rebind", function () {
    initSortables();
  });
});
