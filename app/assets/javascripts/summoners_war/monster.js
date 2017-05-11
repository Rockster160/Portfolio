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
        $('tr[type=' + monster_attr_name + '] td.attr-value').html(monster_attr_val)
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
          skillNameCol = $("<td>").html(this["name"] + "<br>" + "The %calcs"),
          skillDescCol = $("<td>", {colspan: "2"}).html("<p>" + this["description"] + "</p><p>" + this["stat"] + "</p>"),
          skillValCol = $("<td>").html(calculateSkill(this));
      $('table.monsters').append(skillRow.append(skillNameCol, skillDescCol, skillValCol));
    })
  }

  formatFields = function() {
    $('.attr-value, .computed-total').each(function() {
      var fieldVal = getValueFromField(this)
      if (!(fieldVal == 0 || fieldVal)) {
        $(this).html("N/A");
      } else {
        var chars = fieldVal.toString(), charCount = chars.length, formattedStrParts = [];
        while (chars.length > 3) {
          formattedStrParts.push(chars.substr(-3))
          chars = chars.substring(0, chars.length - 3)
        }
        formattedStrParts.push(chars)
        $(this).html(formattedStrParts.reverse().filter(function(part) { return parseInt(part) > 0 || part == "0" }).join(","));
      }
    })
  }

  calculateSkill = function(skillJson) {
    return "9,000";
  //   var skillVal = 0;
  //   $(Object.keys(skillJson)).each(function(idx) {
  //     var statName = this,
  //         statModifierStr = skillJson[statName],
  //         statModifier = statModifierStr[0],
  //         statChange = parseFloat(statModifierStr.substring(1));
  //     //
  //     var statValue = getValueFromField($('tr[type=' + statName + '] .computed-total'));
  //     switch (statModifier) {
  //       case "+":
  //         skillVal += statValue + statChange;
  //         break;
  //       case "-":
  //         skillVal += statValue - statChange;
  //         break;
  //       case "*":
  //         skillVal += statValue * statChange;
  //         break;
  //       case "/":
  //         skillVal += statValue / statChange;
  //         break;
  //     }
  //   })
  //   return skillVal;
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
