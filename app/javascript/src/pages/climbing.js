document.addEventListener("DOMContentLoaded", function() {
  if (!document.querySelector(".ctr-climbs.act-edit")) { return }

  let currentSpan = null;

  function remoteSubmit() {
    const form = document.querySelector("form")
    console.log(form.action)
    fetch(form.action, {
      method: "PATCH",
      body: new FormData(form),
      headers: {
        "Accept": "application/json; charset=UTF-8",
      }
    }).then(function(res) {
      res.json().then(function(json) {
        if (res.ok) {
          console.log(json)
        }
      })
    })
  }

  const output = document.querySelector(".output");

  document.addEventListener("click", function(evt) {
    const key = evt.target.closest(".numpad-key");
    if (key) {
      let input = key.textContent.trim();

      if (input === "<<") {
        let spans = output.querySelectorAll("span");
        if (spans.length > 0) {
          spans[spans.length - 1].remove();
          currentSpan = null
        }
      } else if (input === "%") {
        if (currentSpan && !currentSpan.textContent.includes("%")) {
          currentSpan.textContent += "%";
        }
      } else if (key.classList.contains("climb-submit")) {
        output.querySelectorAll(".current").forEach(span => span.classList.remove("current"));
        currentSpan = null;
        remoteSubmit()
      } else {
        if (!currentSpan) {
          currentSpan = document.createElement("span");
          currentSpan.classList.add("current");
          currentSpan.setAttribute("score", key.getAttribute("score"));
          currentSpan.textContent = input;
          output.appendChild(currentSpan);
        } else {
          currentSpan.textContent += input;
        }
      }

      output.scrollLeft = output.scrollWidth - output.clientWidth;

      let climbSpans = Array.from(output.querySelectorAll("span"));
      let climbs = climbSpans.map(span => span.textContent);
      let scores = climbSpans.map(span => calculateScore(span.textContent, Number(span.getAttribute("score"))));

      document.querySelector("#climb_data").value = climbs.join(" ");
      document.querySelector(".full-score").textContent = roundScore(scores.reduce((a, b) => a + b, 0))
    }
  });

  const scoreFromClimb = function(v_index) {
    const el = Array.from(document.querySelectorAll(".numpad-key")).find(el => el.innerText.includes(v_index))
    if (!el) {
      document.querySelector(".current").classList.add("error")
      return 0
    }

    return Number(el.getAttribute("score"))
  }

  const roundScore = function(score) {
    return parseFloat(score.toFixed(2).replace(/\.?0+$/g, ""))
  }

  const calculateScore = function(input) {
    input = String(input)
    let [score, percentage] = input.split(/[\.\%]/);
    percentage = percentage?.length > 0 ? Number(`0.${percentage}`) : 1;

    return roundScore(scoreFromClimb(score) * percentage);
  }
});
