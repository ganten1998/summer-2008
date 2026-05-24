/* AGD-PATCHED v4 */
theDate= new Date();
var day = theDate.getDate();
var year = theDate.getYear();
year = (year < 2000) ? year + 1900 : year;

function gameDay(){
var numgames = 31;
games = new Array(numgames+1);
games[1]="/agcn/molly/game1_sacrifices/index.html"
games[2]="/agcn/pic_pieces/index.html"
games[3]="/agmg/puzzles/index.html"
games[4]="/agcn/molly/game2_pedalpower/index.html"
games[5]="/agcn/kaya/game1_escape/index.html"
games[6]="/agmg/quizbooks/index.html"
games[7]="/agcn/kit/game2_eggs/index.html"
games[8]="/goml/cecile/cecile.html"
games[9]="/agcn/felicity/game1_penny/index.html"
games[10]="/agmg/pets/html/maze.html"
games[11]="/agcn/trivia/cgi/agctrivia.cgi"
games[12]="/agcn/kirsten/game1_trade/index.html"
games[13]="/agcn/molly/game3_route66/index.html"
games[14]="/agcn/josefina/game1_helping/index.html"
games[15]="/goml/isabel/isabel.html"
games[16]="/agcn/samantha/game1_puzzles/index.html"
games[17]="/agmg/pets/html/pet_quiz.html"
games[18]="/goml/spring_pearl/spr_pearl.html"
games[19]="/agcn/kirsten/game2_activities/index.html"
games[20]="/agcn/samantha/game2_sketchbook/index.html"
games[21]="/goml/minuk/minuk.html"
games[22]="/agcn/josefina/game2_piano/index.html"
games[23]="/agmg/school_smarts/html/ss_pop_quiz.html"
games[24]="/agcn/samantha/game3_morse/index.html"
games[25]="/coconut/game.html"
games[26]="/agcn/felicity/game2_day/index.html"
games[27]="/agcn/kit/railadvn/railadventure_intro.html"
games[28]="/agcn/addy/game1_escape/index.html"
games[29]="/goml/neela/neela.html"
games[30]="/agcn/addy/game2_mancala/index.html"
games[31]="/agcn/kit/game1_schoolyard/index.html"


window.open(games[day],"_parent", config='width=640,height=350, scrollbars=yes, resizable=yes, location=yes');}