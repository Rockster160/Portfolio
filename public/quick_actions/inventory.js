import { hideModal } from "./modal.js";

const loadInventory = () => {
  const tree = document.querySelector(".tree");
  const searchWrapper = document.querySelector(".search-wrapper");
  const inventoryForm = document.querySelector(".inventory-inline-form");
  const searchField = inventoryForm.querySelector("#new_box_name");
  const editModalBtn = document.querySelector(".edit-button");
  const editModal = document.querySelector("#edit-modal");
  const editBoxForm = document.querySelector("#editBoxForm");

  function upsertBox(box) {
    const existingLi = tree.querySelector(`li[data-id='${box.id}']`);
    if (existingLi) {
      existingLi.dataset.type = box.empty ? "item" : "box";
      existingLi.dataset.sortOrder = box.sort_order;
      existingLi.querySelector(".item-name").innerText = box.name;
      existingLi.querySelector(".item-notes").innerText = box.notes || "";
      existingLi.querySelector(".item-description").innerText =
        box.description || "";
      existingLi.dataset.hierarchy = box.hierarchy;
      // TODO: Re-sort
      // TODO: Move to correct/changed parent
      return;
    }

    const template = inventoryForm.querySelector("#box-template");
    if (box && template) {
      const clone = template.content.cloneNode(true);
      const li = clone.querySelector("li");
      li.dataset.id = box.id;
      li.dataset.hierarchy = box.hierarchy;
      li.querySelector(".item-name").innerText = box.name;
      li.querySelector(".item-notes").innerText = box.notes || "";
      li.querySelector(".item-description").innerText = box.description || "";
      li.querySelector("ul[data-box-id='']").dataset.boxId = box.id;
      li.dataset.type = box.empty ? "item" : "box";

      const parentLi = tree.querySelector(`li[data-id='${box.parent_id}']`);
      const ul = parentLi
        ? parentLi.querySelector(`ul[data-box-id='${box.parent_id}']`)
        : tree.querySelector("ul[role=tree]");
      if (ul) {
        if (parentLi) {
          parentLi.querySelector(".empty-box")?.remove();
          parentLi.dataset.type = "box";
          ul.prepend(clone);
        } else {
          ul.querySelector("[data-type=root]").after(clone);
        }
        // ul.appendChild(clone);
        attachDetailsToggleListeners();
        li.scrollIntoView({ behavior: "smooth", block: "center" });
      }
    }
  }

  document.addEventListener("submit", (evt) => {
    const form = evt.target;
    if (!form) return;

    evt.preventDefault();
    const formData = new FormData(form);
    fetch(form.action, {
      method: form.method,
      body: formData,
      headers: {
        accept: "application/json",
      },
    })
      .then((response) => {
        if (response.ok) {
          return response.json();
        } else {
          throw new Error("Network response was not ok");
        }
      })
      .then((data) => {
        const box = data.data;
        upsertBox(box);
        form.reset();
        hideModal("edit-modal");
      })
      .catch((error) => {
        console.error("There was a problem with the fetch operation:", error);
      });
  });

  document.addEventListener("click", function (evt) {
    const li = evt.target.closest("li[data-type]");
    if (li) {
      selectBox(li);
    }
  });

  function attachDetailsToggleListeners() {
    const detailsElements = document.querySelectorAll(
      ".inventory-wrapper details:not(.loaded):not(.pending-load)",
    );

    detailsElements.forEach((details) => {
      const wrapper = details.closest("li[data-id]");
      let loading = details.classList.contains("loading");
      let needsLoad =
        !loading && !!details.querySelector(":scope > ul > li.post-load-box");
      details.classList.add(needsLoad ? "pending-load" : "loaded");
      details.addEventListener("toggle", (event) => {
        if (details.open) {
          if (loading) {
            console.log("Already loading");
          } else if (needsLoad) {
            loading = true;
            details.classList.add("loading");
            console.log("Loading...");
            fetch(`/inventory/boxes/${wrapper.dataset.id}`)
              .then((response) => response.text())
              .then((html) => {
                const ul = details.querySelector(":scope > ul");
                const tempDiv = document.createElement("div");
                tempDiv.innerHTML = html;
                const newUl = tempDiv.querySelector(
                  ":scope > li > details > ul",
                );
                if (newUl) {
                  ul.replaceWith(newUl);
                } else {
                  ul.innerHTML = html;
                }
                details.classList.remove("pending-load");
                details.classList.add("loaded");
                needsLoad = false;
                loading = false;
                attachDetailsToggleListeners();
              })
              .catch((error) => {
                console.error("Error loading box contents:", error);
                details.classList.remove("pending-load");
                details.classList.add("load-error");
              });
          } else {
            console.log("No load needed");
          }

          // console.log("Details element opened");
        } else {
          // console.log("Details element closed");
        }
      });
    });
  }
  attachDetailsToggleListeners();

  function selectBox(li) {
    document.querySelectorAll("li[data-type].selected").forEach((el) => {
      el.classList.remove("selected");
    });

    li.classList.add("selected");
    inventoryForm.querySelector("#new_box_parent_id").value =
      li.dataset.id || "";
    searchField.focus();
    searchWrapper.querySelector("code.hierarchy").innerText =
      li.dataset.hierarchy || "";

    if (li.dataset.type === "root") {
      editModalBtn.disabled = true;
    } else {
      editModalBtn.disabled = false;
      console.log(editModal);
      console.log(editBoxForm);
      const details = li.querySelector(":scope > details > summary");
      const boxName = details.querySelector(".item-name").innerText;
      const boxNotes = details.querySelector(".item-notes").innerText;
      const boxDescription =
        details.querySelector(".item-description").innerText;

      editBoxForm.querySelector("input[name='box_id']").value = li.dataset.id;
      // editBoxForm.querySelector("input[name='parent_id']").value =
      //   li.dataset.parent_id;
      editBoxForm.querySelector("input[name='name']").value = boxName;
      editBoxForm.querySelector("input[name='notes']").value = boxNotes;
      editBoxForm.querySelector("textarea[name='description']").value =
        boxDescription;
    }
  }
};

document.addEventListener("DOMContentLoaded", () => {
  if (document.querySelector(".ctr-inventory_management.act-show")) {
    loadInventory();
  }
});
