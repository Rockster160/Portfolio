function PokeMarker(latlng, map, args) {
  this.latlng = latlng;
  this.args = args;
  this.setMap(map);
}
pokeMarkerJs = function() {
  PokeMarker.prototype = new google.maps.OverlayView();
  PokeMarker.prototype.draw = function() {
    var self = this;
    var div = this.div;
    if (!div) {
      div = this.div = document.createElement('div');
      div.className = 'poke-marker';
      var timer = $('<div/>').addClass('poke-timer');
      $(div).append(timer)
      if (typeof(self.args.poke_id) !== 'undefined') {
        var low_res = 'http://pokeapi.co/media/sprites/pokemon/'
        var high_res = 'http://pokeapi.co/media/img/'
        $(div).css({
          'background-image': 'url("' + low_res + self.args.poke_id + '.png")',
          'background-size': 'cover',
          'background-repeat': 'no-repeat',
          'background-position': 'center center'
        })
      }
      var panes = this.getPanes();
      panes.overlayImage.appendChild(div);
    }
    var point = this.getProjection().fromLatLngToDivPixel(this.latlng);
    if (point) {
      div.style.left = (point.x - 35) + 'px';
      div.style.top = (point.y - 70) + 'px';
    }
  };
  PokeMarker.prototype.remove = function() {
    if (this.div) {
      this.div.parentNode.removeChild(this.div);
      this.div = null;
    }
  };
  PokeMarker.prototype.getPosition = function() {
    return this.latlng;
  };
}
