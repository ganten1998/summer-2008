/* AGD-PATCHED v1 */
// this ticker is for 11 26

/***********************************************
* Memory Ticker script- © Dynamic Drive DHTML code library (www.dynamicdrive.com)
* This notice MUST stay intact for legal use
* Visit Dynamic Drive at http://www.dynamicdrive.com/ for full source code
***********************************************/

var persistlastviewedmsg=0 //should messages' order persist after users navigate away (1=yes, 0=no)?
var persistmsgbehavior="onload" //set to "onload" or "onclick".

//configure the below variable to determine the delay between ticking of messages (in miliseconds):
var tickdelay=4000

////Do not edit pass this line////////////////

var divonclick=(persistlastviewedmsg && persistmsgbehavior=="onclick")? 'onClick="savelastmsg()" ' : ''
var currentmessage=0

function changetickercontent(){
if (crosstick.filters && crosstick.filters.length>0)
crosstick.filters[0].Apply()
crosstick.innerHTML=tickercontents[currentmessage]
if (crosstick.filters && crosstick.filters.length>0)
crosstick.filters[0].Play()
currentmessage=(currentmessage==tickercontents.length-1)? currentmessage=0 : currentmessage+1
var filterduration=(crosstick.filters&&crosstick.filters.length>0)? crosstick.filters[0].duration*1000 : 0
setTimeout("changetickercontent()",tickdelay+filterduration)
}

function beginticker(){
if (tickercontents.length==0)return
if (persistlastviewedmsg && get_cookie("lastmsgnum")!="")
revivelastmsg()
crosstick=document.getElementById? document.getElementById("memoryticker") : document.all.memoryticker
changetickercontent()
}

function get_cookie(Name) {
var search = Name + "="
var returnvalue = ""
if (document.cookie.length > 0) {
offset = document.cookie.indexOf(search)
if (offset != -1) {
offset += search.length
end = document.cookie.indexOf(";", offset)
if (end == -1)
end = document.cookie.length;
returnvalue=unescape(document.cookie.substring(offset, end))
}
}
return returnvalue;
}

function savelastmsg(){
document.cookie="lastmsgnum="+currentmessage
}

function revivelastmsg(){
currentmessage=parseInt(get_cookie("lastmsgnum"))
currentmessage=(currentmessage==0)? tickercontents.length-1 : currentmessage-1
}

if (persistlastviewedmsg && persistmsgbehavior=="onload")
window.onunload=savelastmsg

if ((document.all||document.getElementById)&&tickercontents.length!=0)
document.write('<div id="aroundticker"><div id="memoryticker" '+divonclick+'></div></div>')
if (window.addEventListener)
window.addEventListener("load", beginticker, false)
else if (window.attachEvent)
window.attachEvent("onload", beginticker)
else if (document.all || document.getElementById)
window.onload=beginticker