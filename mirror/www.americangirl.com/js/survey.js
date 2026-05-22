/* AGD-PATCHED v2 */
/* AGD-PATCHED v1 */

function createCookie(name,value,days) {
	if (days) {
		var date = new Date();
		date.setTime(date.getTime()+(days*24*60*60*1000));
		var expires = "; expires="+date.toGMTString();
	}
	else var expires = "";
	document.cookie = name+"="+value+expires+"; path=/";
}

function readCookie(name) {
	var nameEQ = name + "=";
	var ca = document.cookie.split(';');
	for(var i=0;i < ca.length;i++) {
		var c = ca[i];
		while (c.charAt(0)==' ') c = c.substring(1,c.length);
		if (c.indexOf(nameEQ) == 0) return c.substring(nameEQ.length,c.length);
	}
	return null;
}

function eraseCookie(name) {
	createCookie(name,"",-1);
}


function popSurvey() { 
var ckTemp = readCookie("cSurvey")
//alert(ckTemp)	
if (!ckTemp) { // there's no cookie, open survey
	 	//alert("this page has no cookie")
		MM_openBrWindow('html/survey/survey.html','','scrollbars=yes,resizable=yes,width=800,height=600')
    } else { // there is a cookie
		
}
}
