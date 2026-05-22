/* AGD-PATCHED v1 */

var pollCanGo = true;
//var pollCanGo = false;


var ckTemp = document.cookie;


function popPoll()
{ // pop the window;
//set a nopop session variable if this is called from the /fun.html page (GHJ 10-24-03)
if(window.location.pathname=="/fun.html" && !getCookie("HP_POLL_SESSION") ){
        var windPoll = window.open('/html/hp2_poll_1.html','Weekly_Poll','width=260,height=340');
        setCookie("HP_POLL_SESSION",1);
        }
else
var windPoll = window.open('/html/hp2_poll_1.html','Weekly_Poll','width=260,height=340');


}



function setCookie(name, value) { 
 if (value != null && value != "")
  document.cookie=name + "=" + escape(value) + ";";
 ckTemp = document.cookie;
 }
  
function getCookie(name) { 
var cookies = document.cookie;

 var index = cookies.indexOf(name + "=");
// alert("Checking for cookie called " + name + "index is " + index);
 if(index == -1) 
 	return null;
  index = cookies.indexOf("=", index) + 1;
 var endstr = cookies.indexOf(";", index);
 	if (endstr == -1) 
 		endstr = cookies.length;
//alert("Found cookie " + name + " val " + cookies.substring(index, endstr) );

 return unescape(cookies.substring(index, endstr));
 }
  

