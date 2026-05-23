// JavaScript Document

//************popups*******************
var pop = null //window handle
function openPop(URL,w,h){
	if (pop && !pop.closed){//close existing window first
    closePop()
  }
  //if width and height are not explicit, use default values
  var width
  var height
  if(w) width = w
  else width = "500"
  if(h) height = h
  else height = "600"
  
  //open new popup, store in handle variable and set focus
  pop = window.open(URL,"pop","scrollbars=yes,resizable=yes,width="+width+",height="+height+",left=20,top=20")
  pop.focus()
  return false
}

function closePop() {
	//close existing window
  if(pop && !pop.closed) {
    pop.close()
    pop = null //clean up window handle
  }
}

function openLocation(location){
	window.opener.location = location
  window.close()
  return false
}

