/* AGD-PATCHED v1 */


<!--
//alert('webtrends_Tracked');

var dcs_imgarray = new Array;
var dcs_ptr = 0;
var dCurrent = new Date();
var DCS=new Object();
var WT=new Object();
var DCSext=new Object();

var dcsADDR = "dcs.mattel.com";
// DCSID is the unique id for each site
var dcsID = "DCSCDxDhZa4S3eFS0rbrV83F5_6O9N";

if (dcsID == ""){
	var TagPath = dcsADDR;
} else {
	var TagPath = dcsADDR+"/"+dcsID;
}

function dcs_var(){
	WT.tz = dCurrent.getTimezoneOffset();
	WT.ul = navigator.appName=="Netscape" ? navigator.language : navigator.userLanguage;
	WT.cd = screen.colorDepth;
	WT.sr = screen.width+"x"+screen.height;
	WT.jo = navigator.javaEnabled() ? "Yes" : "No";
	WT.ti   = document.title;
	DCS.dcsdat = dCurrent.getTime();
	if ((window.document.referrer != "") && (window.document.referrer != "-")){
		if (!(navigator.appName == "Microsoft Internet Explorer" && parseInt(navigator.appVersion) < 4) ){
			DCS.dcsref = window.document.referrer;
		}
	}

	DCS.dcsuri = window.location.pathname;
	DCS.dcsqry = window.location.search;
// 	This will be the host+domain name only. I.E. www.barbie.com
	DCS.dcssip = "www.americangirl.com";
//	alert (DCS.dcssip);
}

function A(N,V){
	return "&"+N+"="+escape(V);
}

function dcs_createImage(dcs_src)
{
	if (document.images){
		dcs_imgarray[dcs_ptr] = new Image;
		dcs_imgarray[dcs_ptr].src = dcs_src;
		dcs_ptr++;
	}
}

function dcsMeta(){
	var MRV="";
	var F=false;
	var myDocumentElements;
	if (document.all){
		F = true;
		myDocumentElements=document.all.tags("meta");
	}
	if (!F && document.documentElement){
		F = true;
		myDocumentElements=document.getElementsByTagName("meta");
	}
	if (F){
		for (var i=1; i<=myDocumentElements.length;i++){
			myMeta=myDocumentElements.item(i-1);
			if (myMeta.name.indexOf('WT.')==0){
				WT[myMeta.name.substring(3)]=myMeta.content;
			}
			if (myMeta.name.indexOf('DCSext.')==0){
				DCSext[myMeta.name.substring(7)]=myMeta.content;
			}
		}
	}
}


function ClearCG(){
	for (N in DCSext){
		if (N.indexOf('CG')==0){
			delete DCSext[N];
		}
	}
}

function FlashTrack(){
	DCS.dcsuri = null;
         ClearCG();
	for (var I=0;I<arguments.length;I++){
		if (arguments[I].indexOf('WT.')==0){
			WT[arguments[I].substring(3)]=arguments[I+1];
			I++;
		}
		if (arguments[I].indexOf('DCS.')==0){
			DCS[arguments[I].substring(4)]=arguments[I+1];
			I++;
		}
		if (arguments[I].indexOf('DCSext.')==0){
			DCSext[arguments[I].substring(7)]=arguments[I+1];
			I++;
		}
		if (arguments[I].indexOf('dcsID')==0){
			dcsID=arguments[I+1];
			I++;
		}
	}

	if (dcsID == ""){
		var TagPath = dcsADDR;
	} else {
		var TagPath = dcsADDR+"/"+dcsID;
	}

	DCS.dcsdat = dCurrent.getTime();

	if( DCS.dcsuri == null ){
		DCS.dcsuri = WT.ti+".ftrk";
	}
	dcs_TAG(TagPath);
	//alert( "FLASH TRACKED"+DCS.dcsuri );
}

function dcs_TAG(TagImage){
	var P ="http"+(window.location.protocol.indexOf('https:')==0?'s':'')+"://"+TagImage+"/dcs.gif?";
	for (N in DCS){P+=A( N, DCS[N]);}
	for (N in WT){P+=A( "WT."+N, WT[N]);}
	for (N in DCSext){P+=A( N, DCSext[N]);}

	dcs_createImage(P);
}
// This is a sample of the function that would be called if you needed to re-run the script.
//function dcs_ReRun(URI,QRY){
//	DCS.dcsuri = URI;
//	DCS.dcsqry = QRY;
//	dcs_TAG();
//}

dcsMeta();
dcs_var();
dcs_TAG(TagPath);
//-->
