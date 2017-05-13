var currentMonster;
$('.ctr-summoners_wars').ready(function() {

  $('input').on('change input keydown', function() {
    updateCalculations();
  })

  $('.monster-selector').change(function() {
    setCurrentMonster();
  })

  setCurrentMonster = function() {
    currentMonster = undefined;
    var monster_id = $('.monster-selector').val();
    if (!monster_id) { return updateMonsterAttributes(); }
    var url = $('.monster-selector').attr("data-monster-details") + "/" + monster_id;
    $.get(url).success(function(data) {
      currentMonster = data;
      updateMonsterAttributes();
    })
  }

  updateMonsterAttributes = function() {
    if (currentMonster) {
      $(Object.keys(currentMonster)).each(function() {
        var monster_attr_name = this.toString(), monster_attr_val = currentMonster[monster_attr_name];
        $('tr[data-long-type=' + monster_attr_name + '] td.attr-value').html(monster_attr_val)
      })
    } else {
      $('tr[type] td.attr-value').html("N/A");
    }
    updateCalculations()
  }

  updateCalculations = function() {
    $('tr[type!=SKILL]').each(function() {
      var attrVal = getValueFromField($(this).find('.attr-value')), runeVal = getValueFromField($(this).find('.rune-value'));
      if (attrVal || runeVal) {
        attrVal = attrVal || 0;
        runeVal = runeVal || 0;
        $(this).find('.computed-total').html(attrVal + runeVal);
      } else {
        $(this).find('.computed-total').html("N/A");
      }
    });
    updateSkills();
    formatFields();
  }

  updateSkills = function() {
    $('tr[type=SKILL]').remove();
    if (!currentMonster) { return };
    var skills = currentMonster["monster_skills"];
    $(skills).each(function(idx) {
      var skillRow = $("<tr>", {type: "SKILL"}),
          skillNameCol = $("<td>").html(this["name"] + "<br>" + '<ul class="stats"></ul>'),
          skillDescCol = $("<td>", {colspan: "2"}).html("<p>" + this["description"] + "</p><p>" + this["stat"] + "</p>"),
          skillValCol = $("<td>").html(calculateSkill(this, skillNameCol));
      $('table.monsters').append(skillRow.append(skillNameCol, skillDescCol, skillValCol));
    })
  }

  formatFields = function() {
    $('.attr-value, .computed-total').each(function() {
      var fieldVal = getValueFromField(this);
      if (!(fieldVal == 0 || fieldVal)) {
        $(this).html("N/A");
      } else {
        $(this).html(formatNum(fieldVal));
      }
    })
  }

  formatNum = function(num) {
    var chars = num.toString(), charCount = chars.length, formattedStrParts = [];
    while (chars.length > 3) {
      formattedStrParts.push(chars.substr(-3))
      chars = chars.substring(0, chars.length - 3)
    }
    formattedStrParts.push(chars)
    return formattedStrParts.reverse().filter(function(part) { return parseInt(part) > 0 || part == "0" }).join(",")
  }



  skillsFrom = function(url) {
    $.get(url).success(function(data) {
      $(data).find(".basic-tooltip").map(function() { console.log($(this).attr("title")); })
    })
  }


  calculateSkill = function(skillJson, skillNameCol) {
    var skill = skillJson.stat.split("if")[0],
        skillStrings = skill.match(/(\d+|\(.*?\))%( x\d+)?( of the .*? stat)( \+ \d+ damage)?( per hit for \w+ hits)?/g)
        hitsCount = 1,
        multipliers = [];

    $(skillStrings).each(function() {
      var skillStr = this.toString(),
          statStr = skillStr.match(/of the .*? stat/g)[0],
          stat = statStr.substr(7, statStr.length - 12).replace("MAX ", ""),
          hitsStrings = skillStr.match(/(per hit for \w+ hit)|(x\d+)/g),
          hitsStr = hitsStrings == null ? "1" : hitsStrings[0].replace("per hit for ", "").replace(/ hit(s?)/, "").replace("x", ""),
          tempHitsCount = W2N.wordToNumber(hitsStr) || 1;
          multiplier = skillStr.match(/(\d+|\(.*?\))%/g)[0];
      hitsCount = tempHitsCount > hitsCount ? tempHitsCount : hitsCount;
      multipliers.push(multiplier + stat);
    })

    $(skillNameCol).find(".stats").append($("<li>").html(multipliers.join(" + ")));
    $(skillNameCol).find(".stats").append($("<li>").html("Hits: " + hitsCount));
    // $(data[1][0]).find(".basic-tooltip").map(function() { return $(this).attr("title") })
    // Show ?? if based on enemies / if stat cannot be found

    var skillVal = 0;
    $(multipliers).each(function(idx) {
      var statName = this.match(/\w+$/)[0],
          statModifier = this.substr(0, this.length - statName.length);
      //
      var statValue = getValueFromField($('tr[type=' + statName + '] .computed-total'));
      $(statModifier.match(/[a-zA-Z]+/g)).each(function() {
        var statCalc = getValueFromField($('tr[type=' + this.toString() + '] .computed-total'));
        if (statCalc) { statModifier = statModifier.replace(this, statCalc) };
      })
      if (statModifier.trim().slice(-1) == "%") {
        var evaluatedModifier = Math.round(parseFloat(eval(statModifier.slice(0, -1))) / 100);
      } else {
        return skillVal = "??";
      }
      skillVal += evaluatedModifier * statValue;
    })

    return skillVal == "??" ? "??" : formatNum(skillVal);
  }

  parseNum = function(numStr) {
    var sign = "";
    if (numStr[0] == "-") { sign = "-" }
    return parseInt(sign + "0" + numStr.replace(/[^\d]/g, ""));
  }

  hashToString = function(hash) {
    var str = "";
    $(Object.keys(hash)).each(function() {
      var hKey = this, hVal = hash[hKey];
      str += "</br>" + hKey + ": " + hVal;
    })
    return str;
  }

  getValueFromField = function(field) {
    if ($(field).length == 0) { return }
    var rawFieldVal;
    if ($(field).find("input").length == 0) {
      rawFieldVal = $(field).html().trim();
      if (rawFieldVal.length == 0) { return }
    } else {
      rawFieldVal = $(field).find("input").val().trim();
    }
    return parseNum(rawFieldVal);
  }

  updateCalculations();
})
