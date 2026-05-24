/* AGD-PATCHED v4 */
/* AGD-PATCHED v2 */
/* AGD-PATCHED v1 */
var theDictionary = new Array();
var charMap = new Array();

charMap['z'] = 'a';
charMap['a'] = 'b';
charMap['y'] = 'c';
charMap['b'] = 'd';
charMap['x'] = 'e';
charMap['c'] = 'f';
charMap['w'] = 'g';
charMap['d'] = 'h';
charMap['v'] = 'i';
charMap['e'] = 'j';
charMap['u'] = 'k';
charMap['f'] = 'l';
charMap['t'] = 'm';
charMap['g'] = 'n';
charMap['s'] = 'o';
charMap['h'] = 'p';
charMap['r'] = 'q';
charMap['i'] = 'r';
charMap['q'] = 's';
charMap['j'] = 't';
charMap['p'] = 'u';
charMap['k'] = 'v';
charMap['o'] = 'w';
charMap['l'] = 'x';
charMap['n'] = 'y';
charMap['m'] = 'z';

addToDict('qfpj');
addToDict('qdvj');
addToDict('cpyu');
addToDict('avjyd');
addToDict('ypgj');
addToDict('odsix');
addToDict('hvqq');
addToDict('ysyu');
addToDict('bztg');
addToDict('hpqqn');
addToDict('odsix');
addToDict('zqq');
addToDict('qfpj');
addToDict('cpyu');
addToDict('avjyd');
addToDict('bvyudxzb');
addToDict('ysyuqpyuxi');
addToDict('czw');
addToDict('tsjdxicpyuxi');
addToDict('kzwvgz');
addToDict('qdvj');
addToDict('hivyu');
addToDict('wsbbztg');
addToDict('ypgj');
addToDict('bvyu');
addToDict('hvqq');
addToDict('hxgvq');

function checkit(form)
{
   var result = true;
   for (var i=0; i<form.elements.length; i++)
   {
      var e = form.elements[i];
      if (e.type == "text" || e.type == "textarea")
      {
         var parts = e.value.toLowerCase().split(/\W+/);
         for (var w=0; w<parts.length; w++)
         {
            if (theDictionary[parts[w]] == 1)
            {
               result=false;
               break;
            }
         }
      }
   }

   if (!result)
   {
      alert('Please try another word.');
   }
   return result;
}

function addToDict(word)
{
   var newWord = unMunge(word);
   theDictionary[newWord] = 1;
   theDictionary[newWord + 's'] = 1;
   theDictionary[newWord + 'es'] = 1;
   theDictionary[newWord + 'ed'] = 1;
   theDictionary[newWord + 'er'] = 1;
   theDictionary[newWord + 'ing'] = 1;
   theDictionary[newWord + 'y'] = 1;
   theDictionary[newWord + 'ty'] = 1;
}
function unMunge(mungedStr)
{
   var result = "";
   for (var i = 0; i < mungedStr.length; i++)
   {
      result += charMap[mungedStr.charAt(i).toLowerCase()];
   }
   return result;
}
