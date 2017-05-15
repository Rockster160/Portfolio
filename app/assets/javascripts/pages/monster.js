var currentMonster;
$('.ctr-summoners_wars').ready(function() {

  $('.monster-selector').searchableFromSelect({
    templateFromOption: function(option) {
      return '<div>' + option.stars + '<i class="fa fa-star"></i>' + option.text + '</div>';
    }
  })

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
          skillNameCol = $("<td>").html(this['name'] + '<br><p class="normal">' + this["muliplier_formula"] + '</p>'),
          skillDescCol = $("<td>", {colspan: "2"}).html("<p>" + this["description"] + "</p>"),
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
    var splitByDecimal = num.toString().split(".");
    var chars = splitByDecimal[0], decimals = splitByDecimal[1], charCount = chars.length, formattedStrParts = [];
    while (chars.length > 3) {
      formattedStrParts.push(chars.substr(-3))
      chars = chars.substring(0, chars.length - 3)
    }
    formattedStrParts.push(chars)
    var withCommas = formattedStrParts.reverse().filter(function(part) { return parseInt(part) > 0 || part == "0" }).join(",")
    if (decimals) { withCommas = withCommas + "." + decimals };

    return withCommas;
  }

  formatStringOfNums = function(str) {
    $(str.match(/\d+(\.\d+)?/g)).each(function() {
      var isNum = !Number.isNaN(parseFloat(this));
      if (isNum) {
        var rounded = Math.round(this * 10) / 10
        str = str.replace(this, formatNum(rounded))
      }
    })
    return str
  }

  monsterStats = function() {
    var stats = {};
    $('tr[type!=SKILL]').each(function() {
      stats[$(this).attr("type")] = getValueFromField($(this).find('.computed-total'));
    })
    return stats;
  }

  calculateSkill = function(skillJson, skillNameCol) {
    var skill = skillJson.muliplier_formula || "",
        hitsCount = $(skill.match(/x\d+$/))[0],
        multipliers = [];
    if (!skill) { return "N/A" }
    $(skill.match(/(HP|ATK|DEF|SPD|CRI_Rate|CRI_DMG|RES|ACC)/ig)).each(function() {
      skill = skill.replace("\b" + this, getValueFromField($('tr[type=' + this + '] .computed-total')));
    })

    var expr = Parser.parse(skill.replace(/ x\d+$/, "").replace(/(\w) (\w)/g, "$1_$2"));
    // toString twice because toString on the expression returns a number if the
    //   the evaluation completes
    var simplified = expr.simplify(monsterStats()).toString().toString();
    var formatted = formatStringOfNums(simplified);
    if (hitsCount) { formatted = formatted + " " + hitsCount };

    return formatted;
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
