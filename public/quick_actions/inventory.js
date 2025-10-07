const loadInventory = () => {
  const tree = document.querySelector(".tree");
  const searchWrapper = document.querySelector(".search-wrapper");
  const inventoryForm = document.querySelector(".inventory-inline-form");
  const searchField = inventoryForm.querySelector("#box_name");

  inventoryForm.addEventListener("submit", (evt) => {
    evt.preventDefault();
    const formData = new FormData(inventoryForm);
    fetch(inventoryForm.action, {
      method: inventoryForm.method,
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
        const template = inventoryForm.querySelector("#box-template");
        if (box && template) {
          const clone = template.content.cloneNode(true);
          const li = clone.querySelector("li");
          li.dataset.id = box.id;
          li.dataset.hierarchy = box.hierarchy;
          li.querySelector(".item-name").innerText = box.name;
          li.querySelector(".item-description").innerText =
            box.description || "";
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
        inventoryForm.reset();
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
    inventoryForm.querySelector("#box_parent_id").value = li.dataset.id || "";
    searchField.focus();
    searchWrapper.querySelector("code.hierarchy").innerText =
      li.dataset.hierarchy || "";
  }
};

document.addEventListener("DOMContentLoaded", () => {
  if (document.querySelector(".ctr-inventory_management.act-show")) {
    loadInventory();
  }
});
