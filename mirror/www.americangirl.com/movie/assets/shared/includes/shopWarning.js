/* AGD-PATCHED v2 */
/* AGD-PATCHED v1 */
document.documentElement.onclick = processBodyClick

  function legalAgeInform(linkObj,destination,destType){
    var URL = linkObj.href
    if(document.createElement){//show layer for browsers that can handle it
      var warningDIV = document.getElementById("ageWarning")//use existing DIV
      if(!warningDIV){ //OR create new one
      	warningDIV = document.createElement("div")
      	warningDIV.id = "ageWarning"
      	document.body.appendChild(warningDIV)
    	}
      
      //assemble text for popup
      var warningText = "<div id='ageWarningContent'>"
      if(destType == "SWEEP"){
      	warningText += "Sweeps text to go here..."
      }else{ //SHOP -- destType parameter is effectively optional
      	warningText += "<p>You are now going to the American Girl shopping site.<p>"
        warningText += "<p class='eighteen'>Only those 18 and older can purchase online.<p>"
      }
      warningText += "<a href='" + URL + "'>Go to " + destination + "</a>"
      warningText += "</div>"
      warningDIV.innerHTML = warningText
      
      //display warning
      warningDIV.style.display = "block"
      //find relevant dimensions for positioning
      var winSize = findWinSize()//returns array with window dimensions
      var viewHeight = winSize[1]
      var viewWidth = winSize[0]
      var scrollTop = winSize[3]
      var scrollLeft = winSize[2]
      var warningHeight = warningDIV.offsetHeight
      var warningWidth = warningDIV.offsetWidth
      var trigger = findPosSize(linkObj)//returns array with link position and dimensions
      var triggerLeft = trigger[0]
      var triggerTop = trigger[1]
      var triggerWidth = trigger[2]
      var triggerHeight  = trigger[3]

      //center warning over link
      var warningTop = (triggerTop + (triggerHeight/2)) - (warningHeight/2)
      var warningLeft = (triggerLeft + (triggerWidth/2)) - (warningWidth/2)
      
      //move if warning goes off the window (or viewport) to the left or top
      if(warningTop < 0) warningTop = 0
      if(warningLeft < 0) warningLeft = 0
      if(warningTop < scrollTop) warningTop = scrollTop
			if(warningLeft < scrollLeft) warningLeft = scrollLeft
      
      if(warningTop != 0 && warningTop != scrollTop){
        //move if warning goes off the window to the bottom
        if(warningTop + warningHeight > viewHeight){
          if(scrollTop > 0) warningTop = warningTop - ((warningTop + warningHeight) - (viewHeight + scrollTop))
          else warningTop = warningTop - ((warningTop + warningHeight) - viewHeight)
        }
      }
      if(warningLeft != 0 && warningLeft != scrollLeft){
        //move if warning goes off the window to the right
        if(warningLeft + warningWidth > viewWidth){
        	if(scrollLeft > 0) warningLeft = warningLeft - ((warningLeft + warningWidth) - (viewWidth + scrollLeft))
          else warningLeft = warningLeft - ((warningLeft + warningWidth) - viewWidth)
        }
      }
      warningDIV.style.top = warningTop + "px"
      warningDIV.style.left = warningLeft + "px"
      
    }else{//for older browsers, just show an confirm dialog
    	if(confirm("Go to the American Girl shopping site (" + destination + ")?\nOnly those 18 and older can purchase online. ")) window.location = URL
    }
  }
  
  function removeInform(){
    var warningDIV = document.getElementById("ageWarning")
    if(warningDIV){
  		if(warningDIV.style.display != "none"){
      	warningDIV.style.display = "none"
      }
    }
  }
  
  function findPosSize(obj) {//cross-browser position locator and size figger-outer
    if(obj.hasChildNodes()){//handle the case of a linked image
      if(obj.childNodes[0].nodeName.toUpperCase() == "IMG") obj = obj.childNodes[0]
    }
    
    var objWidth = obj.offsetWidth
    var objHeight = obj.offsetHeight    
    var curleft = curtop = 0
    
    //handle the case of an image map 
    //only works with rect shaped area tags and the image map must immediately follow the image that uses it and be in the same container 
    if(obj.parentNode && typeof obj.parentNode.tagName !== "undefined" && obj.parentNode.tagName.toLowerCase()=="map"){
      var coords=obj.coords.split(',')
      objWidth = coords[2]*1 - coords[0]*1
      objHeight = coords[3]*1 - coords[1]*1
      curleft += coords[0]*1
      curtop +=  coords[1]*1
      
      var mapImg = obj.parentNode.parentNode.getElementsByTagName("img")
      for (var i=0;i < mapImg.length;i++){
      	if(mapImg[i].getAttribute("usemap",0) && mapImg[i].getAttribute("usemap",0).replace(/^.*(#.*)/g,'$1') == "#" + obj.parentNode.name){
        	obj = mapImg[i]
        }
    	}
    }
       
  	if (obj.offsetParent) {
  		curleft += obj.offsetLeft
  		curtop += obj.offsetTop
  		while (obj = obj.offsetParent) {
  			curleft += obj.offsetLeft
  			curtop += obj.offsetTop
  		}
  	}
    
  	return [curleft,curtop,objWidth,objHeight]//returns array
  }
  
  function findWinSize(){//cross-browser window-size figger-outer
    //viewport dimensions
    var winWidth = 0
    var winHeight = 0
    //how much scrolling has happened
    var scrollLeft = 0
    var scrollTop = 0
    if(typeof(window.innerWidth) == 'number'){
      //Non-IE
      winWidth = window.innerWidth;
      winHeight = window.innerHeight;
      scrollLeft = window.pageXOffset;
    	scrollTop = window.pageYOffset;
    } else if( document.documentElement && ( document.documentElement.clientWidth || document.documentElement.clientHeight ) ) {
      //IE 6+ in 'standards compliant mode'
      winWidth = document.documentElement.clientWidth;
      winHeight = document.documentElement.clientHeight;
      scrollLeft = document.documentElement.scrollLeft;
    	scrollTop = document.documentElement.scrollTop;
    } else if( document.body && ( document.body.clientWidth || document.body.clientHeight ) ) {
      //IE 4 compatible
      winWidth = document.body.clientWidth;
      winHeight = document.body.clientHeight;
      scrollLeft = document.body.scrollLeft;
    	scrollTop = document.body.scrollTop;
    }
    return [winWidth,winHeight,scrollLeft,scrollTop]//return array
  }
  
	function processBodyClick(e){ //handle click events
  	var clickSrc
  	if(!e) var e = window.event;
  	if(e.target) clickSrc = e.target;
  	else if (e.srcElement) clickSrc = e.srcElement;
  	if (clickSrc.nodeType == 3 || clickSrc.nodeName == "IMG"){ // defeat Safari link bug or handle a linked image
			clickSrc = clickSrc.parentNode
    }
    if(clickSrc.className.indexOf("ageWarningTrigger") != -1){
    	return false //do nothing if clicking trigger link or a linked image
    }
    else removeInform() //otherwise hide warning
  }