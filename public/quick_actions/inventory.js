const loadInventory = () => {
  const searchWrapper = document.querySelector(".search-wrapper");

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
    searchWrapper.querySelector("code.hierarchy").innerText =
      li.dataset.hierarchy || "";
  }

  document.addEventListener("click", function (evt) {
    const li = evt.target.closest("li[data-type]");
    if (li) {
      selectBox(li);
    }
  });
};

document.addEventListener("DOMContentLoaded", () => {
  if (document.querySelector(".ctr-inventory_management.act-show")) {
    loadInventory();
  }
});
