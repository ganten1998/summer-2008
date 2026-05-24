/* AGD-PATCHED v4 */
/* AGD-PATCHED v2 */
/* AGD-PATCHED v1 */


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



//*********contact us validation*********************
var emailChecked = false; //global flag to allow submitting without an e-mail address

function checkForm() {         
  if (document.email_us.Visitors_Message.value == ""){ 
    alert ("Please enter a message.") 
    document.email_us.Visitors_Message.focus(); 
    return false;
  }
  
  var validEmailTest = /^[_a-z0-9-]+(\.[_a-z0-9-]+)*@[a-z0-9-]+(\.[a-z0-9-]+)*(\.[a-z]{2,3})$/;
  if(!validEmailTest.test(document.email_us.from.value) && !emailChecked){
    alert ("If you'd like a response to your message, please enter a valid e-mail address.") 
    document.email_us.from.focus(); 
    emailChecked = true;
    return false;
  }
  
  document.email_us.subject.value = document.email_us.to[document.email_us.to.selectedIndex].text;
  document.email_us.Visitors_Browser.value = navigator.appName + " " + navigator.appVersion;
  document.email_us.Visitors_Platform.value = navigator.platform;
  document.email_us.Visitors_Version.value = navigator.appVersion; 
  
  var message = ""; 
  message += "<br><b>Message: </b>" + document.email_us.Visitors_Message.value; 
  message += "<br><br> Visitors system information:";
  message += "<br><b>Browser: </b>" + document.email_us.Visitors_Browser.value; 
  message += "<br><b>Browser version: </b>" + document.email_us.Visitors_Version.value;
  message += "<br><b>Platform: </b>" + document.email_us.Visitors_Platform.value; 
  document.email_us.MSGCONTENT.value = message; 
  return true;
}
