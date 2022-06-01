import { particlesJSON } from "../support/particles_json"

$(document).ready(function() {
  if ($(".ctr-index.act-home").length == 0) { return }
  particlesJS.load("particles-js", particlesJSON, function() {});
})
