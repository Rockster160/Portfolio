// world is a 2d array of integers (eg world[10][15] = 0)
// 0 == free space
// 1 == blocked
// pathStart and pathEnd are arrays like [5,10]
export function findPath(world, pathStart, pathEnd) {
  // shortcuts for speed
  var	abs = Math.abs;
  var	max = Math.max;
  var	pow = Math.pow;
  var	sqrt = Math.sqrt;

  // NOTE ?? that this A-star implementation expects the world array to be square:
  // keep track of the world dimensions
  // it must have equal height and width. If your game world is rectangular,
  // just fill the array with dummy values to pad the empty space.
  var worldWidth = world[0].length;
  var worldHeight = world.length;
  if (worldWidth < worldHeight) { worldWidth = worldHeight }
  if (worldHeight < worldWidth) { worldHeight = worldWidth }
  var worldSize =	worldWidth * worldHeight;

  // Manhattan style heuristic
  // linear movement - no diagonals - just cardinal directions (NSEW)
  function distanceFunction(Point, Goal) {
    return abs(Point.x - Goal.x) + abs(Point.y - Goal.y);
  }

  // Returns every available North, South, East or West
  // cell that is empty. No diagonals,
  // unless distanceFunction function is not Manhattan
  function Neighbours(x, y) {
    var	N = y - 1,
    S = y + 1,
    E = x + 1,
    W = x - 1,
    myN = N > -1 && canWalkHere(x, N),
    myS = S < worldHeight && canWalkHere(x, S),
    myE = E < worldWidth && canWalkHere(E, y),
    myW = W > -1 && canWalkHere(W, y),
    result = [];
    if (myN) { result.push({x:x, y:N}); }
    if (myE) { result.push({x:E, y:y}); }
    if (myS) { result.push({x:x, y:S}); }
    if (myW) { result.push({x:W, y:y}); }
    return result;
  }

  // returns boolean value (world cell is available and open)
  function canWalkHere(x, y) {
    var withinBoundaries = x >= 0 && x < worldWidth && y >= 0 && y < worldHeight
    return withinBoundaries && world[x][y] <= 0
  };

  // Node function, returns a new object with Node properties
  // Used in the calculatePath function to store route costs, etc.
  function Node(Parent, Point) {
    var newNode = {
      // pointer to another Node object
      Parent:Parent,
      // array index of this Node in the world linear array
      value:Point.x + (Point.y * worldWidth),
      // the location coordinates of this Node
      x:Point.x,
      y:Point.y,
      // the heuristic estimated cost
      // of an entire path using this node
      f:0,
      // the distanceFunction cost to get
      // from the starting point to this node
      g:0
    };

    return newNode;
  }

  // Path function, executes AStar algorithm operations
  function calculatePath() {
    // create Nodes from the Start and End x,y coordinates
    var	mypathStart = Node(null, {x:pathStart[0], y:pathStart[1]});
    var mypathEnd = Node(null, {x:pathEnd[0], y:pathEnd[1]});
    // create an array that will contain all world cells
    var AStar = new Array(worldSize);
    // list of currently open Nodes
    var Open = [mypathStart];
    // list of closed Nodes
    var Closed = [];
    // list of the final output array
    var result = [];
    // reference to a Node (that is nearby)
    var myNeighbours;
    // reference to a Node (that we are considering now)
    var myNode;
    // reference to a Node (that starts a path in question)
    var myPath;
    // temp integer variables used in the calculations
    var length, max, min, i, j;
    // iterate through the open list until none are left
    while (length = Open.length) {
      max = worldSize;
      min = -1;
      for (i = 0; i < length; i++) {
        if (Open[i].f < max) {
          max = Open[i].f;
          min = i;
        }
      }
      // grab the next node and remove it from Open array
      myNode = Open.splice(min, 1)[0];
      // is it the destination node?
      if (myNode.value === mypathEnd.value) {
        myPath = Closed[Closed.push(myNode) - 1];
        do {
          result.push([myPath.x, myPath.y]);
        } while (myPath = myPath.Parent);
        // clear the working arrays
        AStar = Closed = Open = [];
        // we want to return start to finish
        result.reverse();
      } else { // not the destination
        // find which nearby nodes are walkable
        myNeighbours = Neighbours(myNode.x, myNode.y);
        // test each one that hasn't been tried already
        for (i = 0, j = myNeighbours.length; i < j; i++) {
          myPath = Node(myNode, myNeighbours[i]);
          if (!AStar[myPath.value]) {
            // estimated cost of this particular route so far
            myPath.g = myNode.g + distanceFunction(myNeighbours[i], myNode);
            // estimated cost of entire guessed route to the destination
            myPath.f = myPath.g + distanceFunction(myNeighbours[i], mypathEnd);
            // remember this new path for testing above
            Open.push(myPath);
            // mark this node in the world graph as visited
            AStar[myPath.value] = true;
          }
        }
        // remember this route as having no more untested options
        Closed.push(myNode);
      }
    } // keep iterating until the Open list is empty
    return result;
  }

  // actually calculate the a-star path!
  // this returns an array of coordinates
  // that is empty if no path is possible
  return calculatePath();
} // end of findPath() function
