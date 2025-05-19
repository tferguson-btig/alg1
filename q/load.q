arg:((`main;      0b;                                          (); "set true for main task to be run on load");
     (`aws;      "s3://btig-snowflake";                        (); "url for aws");
     (`sftp;     "sftp://qdrop:",string[.z.h],"/incoming/alg"; (); "url for files via sftp");
     (`start;     .z.D-3;                                      (); "start date for load, default is 3 days back");
     (`end;       .z.D;                                        (); "end date for load, default is current date");
     (`datefile;  `:;                                          (); "optional file with dates to load");
     (`replace;   0b;                                          (); "set replace true to replace existing date(s) in db");
     (`get;       0b;                                          (); "set sync true to sync local source files with AWS/sftp files");
     (`getmode;  `aws;                               (`aws`sftp);  "get trade files via aws or sftp");
     (`put;       0b;                                          (); "set put true to update the database");
     (`tasks;      8;                                          (); "number of worker tasks to use to parse files");
     (`db;        .sys.q`alg1`db;                              (); "database directory");
     (`source;    .sys.q`alg`source;                           (); "directory with source files");
     (`tmp;       .sys.tmp[];                                  (); "temporary staging area");
     (`config;    .sys.q`alg1`config;                          (); "dir with configuration files"));

x:.sys.arg[arg;"OMS file loader -- old version";""]

prefix:`alg1                                              /prefix used for database objects
objname:{` sv prefix,x}                                   /creates database object name from prefix
symname:objname`sym                                       /enumeration vector name
enum:{.Q.ens[x;y;symname]}                                /enumeration function given dir & table

/ ------------------------------------------------------------------------------------------------
/ config: read configuration files and return dictionary of tag -> table
/   file: find files by file type for a given date
/  files: return table of files given job args and date
/ ------------------------------------------------------------------------------------------------
config:{
 k: `table,  `column,     `join, `stat, `edge,  `nav,     `navmap;
 v:("bssss"; "ssssbcbbb*"; "ss"; "ss*"; "ssc*"; "sscbb*"; "ss");
 k!{(z;1#"\t")0:` sv x,` sv y,`txt}[x`config]'[k;v]}

file:{[w;d;t]
 k:key w:` sv w,t,` vs`$string d;                      /find hourly subdirs & files within date dir
 i:where not b:v~'f:key each v:(` sv w,)'[k];          /b:true if file, i:indices of subdirs
 f:{(` sv x,)'[y]}'[v i;f i];                          /hourly files
 f:ungroup flip`eod`hour`file!(0b;"H"$string k i;f);   /table of eod flag, hour, files
 f,:flip`eod`hour`file!(1b;0Nh;v where b);             /add dayend summary file(s)
 `date`filetype xcols update date:d,filetype:t from f}

files:{[x;d]raze file[w;d]'[key w:x`source]}

/ -------------------------------------------------------------------------------------------------
/  filegroup: organize files by type, with column,name,qtype and name of staging table
/     dotsym: symbol + symbol_suffix = symbol.suffix, delete symbol_suffix column
/   parsesym: check for symbol & suffix columns, create single symbol column
/  parsetime: convert UTC-flagged columns to local time, convert 'expire' timestamp -> date
/  parsebool: convert column of True/False or Yes/No symbols to boolean, True/Yes -> 1b, 0b else
/ -------------------------------------------------------------------------------------------------
filegroup:{[c;f]
 g:`filetype xgroup c`column;
 g:update stage:(exec filetype!stage from c`table where not stream)filetype from g;
 g:update file:(exec file by filetype from f)filetype from g;
 select[<([]not stage like"*history";not stage like"order*";stage)] from 0!g}

dotsym:{delete symbol_suffix from update symbol:{$[null y;x;` sv x,y]}'[symbol;symbol_suffix]from x}
parsesym:{$[all`symbol`symbol_suffix in cols x; dotsym x; x]}
parsetime:{[u;x] @[;cols[x]inter`expire;"d"$]@[x;u;ltime]}
parsebool:{[b;x] @[x;b;in[;`True`Yes]]}

/ -------------------------------------------------------------------------------------------------
/    idcheck: return ok flag & indices if not all ok, printing warning on count of filtered rows
/   idfilter: check root order id for unexpected dates, e.g. Oct 9,12 & Nov 22,2024
/  parsetext: unpack column specs, parse text, then convert utc, make booleans, symbol+suffix
/  parsebloc: parse text, enumerate, append to dir for splayed table
/  parsefile: use .Q.fsn to parse file in blocks (to preserve memory when parsing larger files)
/  parsecols: determine q type of all fields, names for fields to use, boolean & utc time cols
/  parsetype: retrieve staging table name, column names and qtype for parsing a filetype
/ parsefiles: parse a day's files (end-of-day or intraday), save to staging dir
/ -------------------------------------------------------------------------------------------------
idcheck:{[d;t;x]
 b:all a:("D"$(2#string d),/:6#'x`id)in d+0 1;
 $[b; x; [.sys.msg("Warning: ";count[x]-count i:where a;"unexpected order id(s) in";t); x i]]}

idfilter:{[d;t;x] $[`id in cols x; idcheck[d;t;x]; x]}
parsetext:{[c;d;t;x] (q;s;b;u):c; idfilter[d;t]parsesym flip parsebool[b]parsetime[u]s!(q;"`")0:x}
parsebloc:{[w;c;d;t;x] @[` sv w,t;`;,;enum[w]parsetext[c;d;t;x]]}
parsefile:{[w;c;d;t;f] .Q.fsn[parsebloc[w;c;d;t]; f; 100000000]}
parsecols:{(s;q;a;b;u):x`name`qtype`use`bool`utc; q:?[a&:not null q;q;" "]; (s;b;u):(s where@)'[(a;a&b;a&u)]; (q;s;b;u)}

parsetype:{[w;d;g]
 p:.z.P; c:parsecols g; parsefile[w;c;d;g`stage]'[g`file];
 .sys.msg("Parsed"; 24$string g`filetype;"->";10$string g`stage;"in";"v"$.z.P-p)}

parsefiles:{[w;c;d;e;f]
 p:.z.P; .sys.msg("Parsing"; ("intraday";"day-end")e; "files for"; d);
 parsetype[w;d] peach filegroup[c]f;
 .sys.msg("Parsing of"; ("intraday";"day-end")e; "files complete for"; d; "v"$.z.P-p)}

/ ------------------------------------------------------------------------------------------------
/  secadj: set put/call and expire date for options, unset cases where exchange code too long
/ secattr: retreive security attributes from leg, leghistory and fill tables
/ nullval: return true if null or near-empty (in case of string name)
/ bestval: pick first non-null value of attribute for group, e.g. symbol & sedol
/ fillval: pick "best" value for attributes by group, e.g. symbol,sedol or symbol,strike,pc,expire
/ secuniq: fill in null values for country from ISIN or exchange, fill nulls to reduce duplicates
/  secdup: print cases where duplicate security attributes by symbol,country,strike,pc,expire
/ secsort: return duplicate cases and table of security definitions sorted by symbol,country,..
/ secsave: save unique set of security identifiers
/ ------------------------------------------------------------------------------------------------
secadj:{update "d"$expire,first'[string pc],                  /expire date from datetime value, Put/Call -> P/C
               exchange:?[exchange like"??????*";`;exchange]  /e.g. Oct 8 2024, exchange codes set to ISIN (?)
          from x}

secattr:{[w]
 t:`fill`leg`leghistory;
 c:`symbolref`symbol`cusip`sedol`isin`sectype`eqtype`strike`pc`expire`underlying`exchange`primary`country`name;
 distinct uj/[{[c;w;t]distinct secadj(c inter cols t)#t:w . t,`}[c;w]'[t]]}

nullval:{$[type x;null x;count'[x]<2]}
bestval:{x first where not nullval x}
fillval:{[t;k;c]?[t where not any null t k;();k!k,:();c!(bestval;)'[c:c except k]]}

secuniq:{[t]
 t:update equity:1b from t where sectype=`Equity;
 t:update country:`US from t where equity,null country,any(symbolref like"*|US"; isin like"US*"; exchange=`US);
 t:update country:`CA from t where equity,null country,any(symbolref like"*|CA"; isin like"CA*"; exchange like"C?");
 t:update country:`HK from t where equity,null country,exchange=`HK;
 c:`symbolref`cusip`isin`sedol`eqtype`exchange`primary`underlying`country`name;
 t:t lj fillval[select from t where equity;`symbol`sedol;c];
 t:t lj fillval[select from t where not equity;`symbol`strike`pc`expire;c];
 distinct t}

secdup:{[d;a]
 if[count t:select from a where equity;
  .sys.msg(count t;"rows with duplicate equity definitions for";d);
  .sys.indent[40]select symbol,exchange,country,eqtype,`$name,cusip,sedol,isin from t];
 if[count t:select from a where not equity;
  .sys.msg(count t;"rows with duplicate option/other definitions for";d);
  .sys.indent[40]select symbol,exchange,country,sectype,strike,pc,expire from t]}
 
secsort:{[d;t]
 t:update us:country=`US from t;
 t:select[<([]symbol;country;strike;pc;expire;sum not nullval each flip t)]from t;
 if[b:0<count a:select from t where 1<(count;i)fby([]symbol;country;strike;pc;expire); secdup[d]a];
 t:$[b; 0!select by symbol,country,strike,pc,expire from t; t];
 c:`symbol`equity`us`sectype`eqtype`strike`pc`expire`underlying`cusip`isin`sedol`exchange`primary`country`name;
 c#/:(a;t)}

secsave:{[d;w]
 symname set w symname;
 {(` sv x,y,`)set enum[x]z}[w]'[`secduplicate`security; secsort[d]secuniq secattr w]}

/ --------------------------------------------------------------------------------------------------
/  fillerror: return table of errors in fill chains & updated fills w'chain from client->market fill
/ fillreport: display count of incomplete chains and their routes
/    fillmap: create 2 maps: fill->child, fill->leaf for corrected fill chains
/  fillpatch: fix incomplete chains, setting child fill to allow chain from client->market fill
/  fillcheck: check for incomplete fill chains where client fill not linked to ultimate market fill
/  fillorder: use order event history to get map from fill -> order, correct corrupt chains in fills
/  fillwrite: check & patch incomplete fill chains, set leaf for all fills
/ --------------------------------------------------------------------------------------------------
fillerror:{[f]
 f:update err:0b,p:{$[20h=type x;get x;x]}[tier]fill?/:c from update c:.sys.chain[fill;child]from f;
 f:update err:1b from f where tier=`Client,not any(p~\:1#`Client;last'[p]=`Market);
 e:select fill:last'[c],c1:c from f where err;
 e:e lj 1!select fill,s:system_exec_id from f where fill in e`fill;
 e:e lj 1!select s:system_exec_id,child:fill,c2:c from f where system_exec_id in e`s,not child~'system_exec_id;
 (select fill,child,c:c1 union'c2 from e; f)}

fillreport:{[d;f]
 n:count first(e;f):fillerror f;
 .sys.msg(n;"broken chains where client fill not linked to market fill for";d);
 if[n;.sys.indent[100; select n:count i by chain:{x where differ x}'[p]from f where tier=`Client];
      .sys.indent[100; select n:count i by route,execution_route from f where err]];
 (e;f)}

fillmap:{(exec fill!child from x;exec raze {(-1_x)!(-1+count x)#-1#x}'[c] from x)}

fillpatch:{[d;e;f]
 .sys.msg(count e;"broken chains to be patched using system_exec_id for";d);
 (m1;m2):fillmap e;
 f:update child:m1 fill from f where fill in key m1;
 f:update leaf:m2 fill from f where fill in key m2;
 fillreport[d;f]}

fillcheck:{[d;w]
 .sys.msg("Checking for broken chains in fills (BTAL bug) for";d);
 f:select tier,route,execution_route,`u#fill,child,leaf,childamend,leafamend,system_exec_id from w`;
 if[count first(e;f):fillreport[d;f]; (e;f):fillpatch[d;e;f]]; (e;f)}

fillorder:{[f;h]
 m:exec {(k!v):y first each group x;(`u#k)!v}[fill]amend from h` where event=`Fill; /map fill -> order from event history
 f:update b:1b,childamend:m child from f where {not any(x like"";x~'y)}[m child;childamend];
 .sys.msg(n:sum f`b;"child order id's corrected in fills to match order event data");
 if[n; .sys.indent[100]select n:count i by route,execution_route from f where b];
 f:update b:0b from f;
 f:update b:not leafamend like"",leafamend:m leaf from f where not leafamend~'m leaf;
 .sys.msg(n:sum f`b;"leaf order id's corrected in fills to match order event data");
 if[n; .sys.indent[100]select n:count i by route,execution_route from f where b];
 delete b from f}

fillwrite:{[d;w]
 (wf;wh):(` sv w,)'[`fill`history]; (e;f):fillcheck[d;wf];
 f:update leaf:fill from f where leaf like"",p in 1#'`Client`Market;
 f:fillorder[f;wh];
 @[wf;c;:;f c:`child`leaf`childamend`leafamend]}

/ -------------------------------------------------------------------------------------------------
/  joingroup: return table of main table, join column(s) and secondary tables
/   joinmove: main table & secondary table align exactly on key, can just move column files
/  joinindex: main table & secondary aren't aligned, get index of main keys in secondary, reindex
/    joinmsg: formats the result of the join, whether both tables aligned, omitted columns
/  joinstage: perform one step of join, e.g. `leg with `leg1, aligning/reindexing on key column(s)
/ joinstages: join intermediate staging tables to main table, e.g. order with order1,order2,..
/ -------------------------------------------------------------------------------------------------
joingroup:{[c]
 g:lj/[(select col by table from c`join;select stage by table from c`table where not stream)];
 select table,col,stage:stage except'table from g}

joinmove:{[w;a] {.sys.rename . a:` sv'x,'y; if[{x~key x}first a:`$string[a],'"#";.sys.rename . a]}[reverse w]'[a]}
joinindex:{[w;a;i] {@[x 0;z;:;@[x 1;z]y]}[w;i]'[a]}

joinmsg:{[s;t;b;c;z]
 m:("Joined"; 6$string s; "to"; 6$string t; "using";","sv string c);
 m,("(",$[b;"";"NOT "],"aligned,"; $[count z; "deleted: ",","sv string z;"no columns deleted"],")")}

joinstage:{[w;c;t;s]
 w:(` sv w,)'[(t;s)]; a:w@'`.d; z:inter/[a] except c; /path for main & secondary table, cols, overlap
 a:a[1]except a 0;                                    /cols to add to table t from secondary table s
 if[not b:~/[k:w@\:c]; i:?/[{flip x!y}[c]'[k 1 0]]];  /b true if key column(s) align exactly, else lookup
 $[b;joinmove[w]a; joinindex[w;a]i];                  /move cols to main table or reindex and write
 @[w 0;`.d;union;a]; .sys.rmdir last w;               /add new column names, erase secondary table dir
 .sys.msg joinmsg[s;t;b;c;z]; t}

joinstages:{[w;g] joinstage[w;g`col]/[g`table;g`stage]}

/ -------------------------------------------------------------------------------------------------
/      legno: 0 if single leg, 1,2,.. for multi-leg counts
/     legnos: return a list of leg numbers given leg counts
/     addcol: add column name to directory list saved in .d file
/    joinleg: join orders to leg data defining symbol, limit price, qty, etc.
/  joinhist1: sort history by id & sequence number, repeat each row for number of legs
/  joinhist2: reindex history using index that orders by id,seq and expands for multiple legs
/  joinhist3: add leg number and leg id using the number and id from the order table
/  joinhist4: add leg history to order history and define column order
/   joinhist: join order history with leg history
/ jointables: join order+leg, history+leg history
/ -------------------------------------------------------------------------------------------------
legno:{$[x=1;0;1+til x]}
legnos:{raze legno'[get count each group x]}
addcol:{[c;x]@[x;`.d;union[;c]]}

joinleg:{[w]
 .sys.msg"Joining order & leg, step 1: sorting by order id & leg";
 l:` sv w,`leg;   n:count i:iasc`id`legid#l`;
 o:` sv w,`order; m:count i@:where l[`id][i]in o`id;
 if[m<n; .sys.msg("Warning:";n-m;"leg record(s) without matching order id")];
 .sys.msg"Joining order & leg, step 2: rewriting leg cols in sorted order";
 @[l;;@[;i]]peach l`.d; @[l;`id;`s#]; @[l;`leg;:;legnos l`id];
 i:o[`id]?l`id; oc:o[`.d]except lc:`leg,l`.d;
 .sys.msg"Joining order & leg, step 3: aligning orders with sorted leg data";
 {[l;o;i;c]@[l;c;:;o[c]i]}[l;o;i]peach oc;
 @[l;`.d;:;{x,y except x}[`id`tier`route`parent`client`leg`legid`symbol`sectype`side]oc,lc];
 .sys.rmdir o; .sys.rename[l;o]}
 
joinhist1:{[o;h]
 .sys.msg"Joining order & leg history, step 1: sorting by order id & sequence";
 n:exec count i by id from k:`id`leg`legid#o`; /leg number,id and counts per id from orders
 i:iasc `id`seq#h`; b:null n@:h[`id]i;         /sort history by id & sequence,expand for multileg
 if[any b; .sys.msg("Warning:";sum b;"history records omitted because no order data found")];
 (i where 0^n;k)}  /return indices to sort history by id & sequence, expanding for legs, also id-leg keys

joinhist2:{[h;i]
 .sys.msg"Joining order & leg history, step 2: re-indexing cols in id,sequence order,expanding for legs";
 @[h;;@[;i]]peach h`.d; @[h;`id;`s#]} /arrange history cols w'sorted/expanded index, set sort attr for id

joinhist3:{[h;k]
 .sys.msg"Joining order & leg history, step 3: assigning leg number & id for each history row";
 addcol[`leg]  @[h;`leg;:;{raze(legno count@)each where[x]_x}differ`id`seq#h`]; /assign leg number within id & sequence
 addcol[`legid]@[h;`legid;:;((select id,leg from h`)lj 2!select from k)`legid]} /assign legid used in orders

joinhist4:{[h;l]
 .sys.msg"Joining order & leg history, step 4: find leg history in sorted order history, add leg columns";
 i:((select change,legid from h`)lj 2!update j:i from select change,legid from l`)`j;
 {[h;l;i;c]@[h;c;:;l[c]i]}[h;l;i]peach lc:l[`.d]except hc:`leg`legid,h`.d; .sys.rmdir l;
 @[h;`.d;:;{x,y except x}[`id`seq`event`confirm`status`change`leg`legid`symbol`sectype`side]hc,lc]}

joinhist:{[w]
 (o;h;l):(` sv w,)'[`order`history`leghistory];
 joinhist2[h]first (i;k):joinhist1[o;h]; joinhist3[h;k]; joinhist4[h;l]}

jointables:{[c;d;w]
 joinstages[w]peach joingroup c; secsave[d;w];
 joinleg w; joinhist w;
 .sys.msg"Table joins completed"}

/ --------------------------------------------------------------------------------------------
/ edgedelim: edge files use "#$#" as delimiter
/  edgedate: read date from first file record by converting UTC timestamp to date
/  edgefile: find file(s) matching date by reading 1st record (date in name is a day earlier)
/  edgeread: remap original delimiter -> tab, parse using configuration file definitions
/  edgepick: warn if no file, or pick largest file if multiple edge statistics files found
/  edgesave: parse, update, sort and save edge statistics for given date
/ --------------------------------------------------------------------------------------------
edgedelim:"#$#"
edgedate:{$[count x:first read0(x;0;100); "d"$ltime d first where not null d:"P"$'edgedelim vs x; 0Nd]}
edgefile:{[d;f]exec file from f where filetype=`EdgeStatistics,date within -5 0+d,d=edgedate'[file]}
edgeread:{[c;f] flip{(count[y]#x)!y}[c`name](c`qtype;"\t")0:{"\t"sv edgedelim vs x}each read0 f}

edgepick:{[d;f]
 if[0=n:count f; .sys.msg("Warning: no edge statistics file found for";d)];
 if[n>1; .sys.msg("Warning:";n;"edge statistics files found for";d;"-- using largest"); j:first idesc m:hcount'[f];
         .sys.indent[20]([]pick:@[n#`$"-";j;:;`Largest]; size:m; file:last each"/"vs'string f)];
 $[n=0;`;n>1;f j;first f]}

edgesave:{[w;c;f;d]
 .sys.msg("Saving edge statistics for";d);
 (s;q):(c@:`edge)`name`qtype; e:flip s!q$\:(); f:edgepick[d]edgefile[d]f;
 t:update ltime time,`True=cancel from e uj $[null f; (); edgeread[c]f];
 (` sv w,`edge`)set enum[w]`id`time xasc t}

/ ------------------------------------------------------------------------------------------------
/  navwarn: warn if if header contains undefined tags
/  navcols: match up file header with column definitions
/  navtime: convert UTC timestamp/timespan to local time
/  navbool: convert columns with `True`False to boolean
/  navsize: convert string like '500:0.25|600:0.25|750:0.25|1000:0.25' -> 500 600 750 1000
/   navsym: convert symbol in navigator file from space-separated suffix to dot-separated
/  navcast: recast string -> sizes, True/False to boolean, UTC time to local
/  navread: given tag,name,type,utc & bool flags and file/data, returns table of navigator data
/  navdate: return trade date given file or null if no trade date can be determined
/  navfile: given table of edge/navigator statistics files, selects relevant files for given date
/ ------------------------------------------------------------------------------------------------
navwarn:{[g;h] if[count a:h except g; .sys.msg("undefined tag in NAV file:";","sv string a)]}
navcols:{[c;h](g;q):c`tag`qtype; navwarn[g]h; i@:where not null q@:i:g?h; (q;c[i]`name`utc`bool)}
navtime:{[u;t] @[t;cols[t]where u;{$[12h=type y;ltime y;ltime[x+y]-x+00:00]}t`date]}
navbool:{[b;t] @[t;cols[t]where b;{x=`True}]}
navsize:{[t]@[t;cols[t]inter`sizes;{first"J:|"0:x}']}
navsym:{[t]@[t;cols[t]inter`symbol;.sys.sym[`cms]`dot]}
navcast:{[u;b;t]navsym navsize navbool[b]navtime[u]t}
navread:{[c;d;f](q;(s;u;b)):navcols[c]h:`$"`"vs first x:read0 f; navcast[u;b]s xcol(q;1#"`")0:x}
navdate:{[f]$[2>count x:read0(f;0;20000); 0Nd; {"D"$y first where x like"TradeDate"}."`"vs'2#x]}
navfile:{[f;d]select from f where filetype=`NavStatistics,not null alg,date within d-3 0,navdate'[file]=d}

/ ------------------------------------------------------------------------------------------------
/  navtemp: name of temporary navigator dir within working directory
/ navdate1: filter out any records where date in records doesn't match reference date
/ navsave1: 1st stage: read navigator files by algorithm and save to splayed directory
/ navsave2: 2nd stage: read algorithm tables by navigator instance, join on id to single table
/ navsave3: 3rd stage: append navigator tables together to single temp/nav/ splayed table
/  navsave: read files by navigator instance & alg, join by alg within navigator, then union
/ ------------------------------------------------------------------------------------------------
navtemp:{` sv x,`navtemp}

navdate1:{[d;t]
 n:count t; n-:count t:delete date from select from t where date=d; 
 if[n; .sys.msg("Warning:";n;"file row(s) with unexpected trade date")]; t}

navsave1:{[w;c;d;x]@[` sv navtemp[w],n,a; `; :; enum[w]navdate1[d]@[navread[c;d]x`file;`nav;:;first(n;a):x`nav`alg]]}
navsave2:{(i;w;v):x; @[` sv first[` vs w],`$string i; `; :; 0!lj/[{`navid xkey select from x`}'[v]]]}
navsave3:{[w;e;r] v:@[` sv w,`nav;`;:;e:enum[w]e]; {@[x;`;,;y uj select from z`]}[v;e]'[r]; v}

navempty:{[c]
 (s;q;b):c`name`qtype`bool; q@:i:where not null q; e:delete date from navbool[b i]flip s[i]!q$\:();
 c:`nav`alg`time`event`trigger`start`end`symbol`side`phase`style`dest`route`mic`ordertype`subtype`workingtype`orderkey`id`orderid`reroute;
 c xcols update nav:` from e}

navsave:{[w;c;f;d]
 c@:`nav; f:navfile[f]d;
 .sys.msg(count f;"navigator files for";d);
 r:navsave1[w;c;d]peach select[>alg=`Main]from f;
 /`:/tmp/navmap 0:","0:select[<([]alg<>`Main;alg)]from distinct ungroup([]alg:(last` vs)'[r];name:r@'`.d);
 r@:group(first` vs)'[r]; .sys.gc[]; p:.sys.pd0[];
 r:navsave3[w;navempty c]navsave2 peach flip(til count r;key r;get r);
 .sys.rmdir navtemp w; .sys.pd1 p;.sys.gc[]; .sys.msg("navigator update completed")}

/ ------------------------------------------------------------------------------------------------
/  statfile: given file name as string, attempt to get type, navigator source, algorithm & date
/  statsort: sort files by date, filetype, algorithm, navigator source
/ statfiles: return table of edge & navigator statistics files
/  statsave: save edge and navigator statistics for given date
/ ------------------------------------------------------------------------------------------------
statpath:`QuantData`QuantData_New
statfile:{update"D"$10#date from`filetype`nav`alg`date!"SSS*"$x $[2=n:count x:"_"vs x;0 0N 0N 1;n=3;0 1 0N 2;til 4]}
statsort:{`date`filetype`alg`nav xasc x}

statfiles:{[c;x]
 c@:`stat; k:key each w:(` sv x[`source],)'[c`dir]; k:{x where x like y}'[k;c`filemask];
 statsort statfile'[string raze k],'([]file:raze f:{(` sv x,)'[y]}'[w;k])}

statsave:{[x;w;c;d] f:statfiles[c;x]; edgesave[w;c;f;d]; navsave[w;c;f;d]}

/ ------------------------------------------------------------------------------------------------
/  syncmode: check for supported mode of transferring, only `aws currently implemented
/  syncfile: retrieve file name from sync output, use readlink to get absolute path
/  syncpath: given string of remote & local path, run sync and return list of new/updated files
/  syncdate: generate the paths to sync from AWS s3 bucket to local dirs for single date
/  syncsum1: summarize trading system files retrieved by filetype, first,last date(s)
/  syncsum2: summarize edge/nav statistics files retrieved 
/  syncstat: sync local source dirs with edge & navigator statistics, return files downloaded
/ syncdates: sync trading system files from AWS s3 for given date(s)
/ syncstats: sync edge/navigator statistics files from AWS to local source directory
/ ------------------------------------------------------------------------------------------------
syncmode:{if[`aws<>x`getmode; '"nyi: getmode=`",string x`getmode]}
syncfile:{(.sys.readlink last@)'[" to "vs/:x]}
syncpath:{syncfile system" "sv(.sys.which`aws;"s3 sync"; x; "--no-progress")}

syncdate:{[x;t;d]
 a:` sv hsym[`$x`aws],`Analytic;
 .sys.msg("Syncing source files with"; 1_string a;"for";d);
 v:t,\:` vs`$string d;                                        /add yyyy mm dd to each file type
 v:" "sv'flip 1_''string{(` sv y,)'[x]}[v]'[(a;x`source)];    /pair remote and local dirs for date
 f:raze syncpath each v;                                      /get full path of new/updated files
 t:`${$[count x:x inter "/" vs y;first x;"(unknown type)"]}[string t]'[f];  /derive file type from path
 ([]date:d; filetype:t; file:f)}

/patch for header of streaming Orders files:
/ssr[hh;"`NoTCross`VenueBlacklist`VenueBlacklist";"`NoTCross`NoExchanges`VenueBlacklist"]

syncstream:{[x;t;d]
 a:` sv hsym[`$x`aws],`Analytic`Streaming;
 b:` sv x[`source],`Streaming;
 .sys.msg("Syncing source files with"; 1_string a;"for";d);
 v:t,'`$@[string d;4 7;:;"-"];
 v:" "sv'flip 1_''string{(` sv y,)'[x]}[v]'[(a;b)];    /pair remote and local dirs for date
 f:raze syncpath each v;                               /get full path of new/updated files
 t:`${$[count x:x inter "/" vs y;first x;"(unknown type)"]}[string t]'[f];  /derive file type from path
 ([]date:d; filetype:t; file:f)}

syncsum1:{select files:count i,start:first date,end:last date by filetype from x}
syncsum2:{delete date from statsort ((statfile last@)each v),'([]file:"/"sv'-2#'v:"/"vs'x)}
syncstat:{.sys.msg("Syncing source files with"; first p:1_'string` sv'(hsym`$x`aws;x`source),'y); syncpath" "sv p}

syncdates:{[x;c;d]
 syncmode x; t:asc exec filetype from c`table where not stream;
 f:`date xasc $[0>type d; syncdate[x;t;d]; raze syncdate[x;t]peach d];
 if[count f;.sys.msg(count f;"file(s) downloaded"); .sys.indent[100]syncsum1 f]}

syncstats:{[c;x]
 syncmode x; f:raze syncstat[x]peach c .`stat`dir;
 if[count f;.sys.msg(count f;"edge/nav statistics file(s) downloaded"); .sys.indent[100]syncsum2 f]}

/ --------------------------------------------------------------------------------------------
/  datefile: check optional date file, read in dates
/ daterange: check start & end date, return derived range, if null return past week
/ datelabel: return string summarizing date(s)
/   datetag: create date label using overall job args to determine if date file used
/  checkarg: check that job args are defined, valid writable directories, etc.
/ checkdate: check date(s) from given start,end or file, look for corresponding source files
/ --------------------------------------------------------------------------------------------
datefile:{@[{(0b;{asc x where not null x}"D"$read0 x)};x;{(1b;"datefile: ",x)}]}
daterange:{$[count r@:where not null r:x`start`end; {x+til 0|1+y-x}. 2#r; d where 1<(d:.z.D-reverse til 7)mod 7]}
datelabel:{[r;d]$[1>=n:count d;string first d; r; " - "sv string d 0,n-1; (", "sv string 2#d),$[n>2;" .. ",string last d;""]]}
datetag:{[x;d] datelabel[null last` vs x`datefile]d}

checkarg:{
 $[count a:where[{$[0>type x;null x;0=count x]}'[x]]except`start`end;
   (1b; "arg: ",(","sv string a),", not defined");
   count a:where not 2h=.sys.filetype each`config`db`source`tmp#x;
   (1b; "arg: ",(","sv string a)," not directory");
   count a:where not "/"=string[`config`db`source`tmp#x][;1];
   (1b; "arg: ",(","sv string a)," not absolute path");
   count a:where not .sys.writeflag each($[x`put;`db`tmp;()],x[`get]#`source)#x;
   (1b; "arg: ",(","sv string a)," not writeable directory");
   (0b; "")]}

checkdate:{
 if[first a:$[r:null last` vs f:x`datefile; (0b;daterange x); datefile f]; :a];
 if[0=count d:asc distinct last a; :(1b;"no dates defined from given ",$[r;" start & end";"file"])];
 (0b;d)}

/ ---------------------------------------------------------------------------------------------
/ putdate: update database with trading files for given date
/    date: get/put files for given date
/   dates: process each date's files, save to partitioned kdb database if put flag true
/    main: initialize grid tasks, process given date(s)
/ ---------------------------------------------------------------------------------------------
puterr:{[x;d;e;f]
 if[0=count f; .sys.msg("Warning: no";$[e;"dayend";"intraday"];"files for";d); :1b];
 n:sum hcount'[exec file from f where filetype=`OrderData];
 if[n<100000; .sys.msg("Warning: only";n;"bytes of";$[e;"dayend";"intraday"];"order data for";d); :1b];
 if[not[x`replace]&(`$string d)in key x`db; .sys.msg("Date:"; d;"already in database"); :1b];
 0b}

putdate:{[x;c;d;e]
 if[puterr[x;d;e]f:select from files[x;d]where eod=e; :()];
 t:.z.P; .sys.gc[]; w:.sys.tempdir x`tmp; .sys.symset[x`db;w;symname];
 parsefiles[w;c;d;e;f]; fillwrite[d;w]; jointables[c;d;w]; statsave[x;w;c]d;
 {.sys.rename .(` sv x,)'[y,objname y]}[w]'[key[w]except symname];
 .sys.msg("Moving tables for";d;"from working directory to database");
 .sys.symadd[x`db;w;symname]; hdel` sv w,symname; .sys.addpart[x`db;w;d];
 .sys.msg("Total runtime for";d;"is";"v"$.z.P-t;.sys.used 0)} 

date:{[x;c;d] if[x`get; syncdates[x;c]d]; if[x[`put]&mod[d;7]>1; putdate[x;c;d;1b]]}

dates:{
 (x;d):x; c:config x;
 .sys.msg("ALG database job --"; datetag[x]d);
 if[x`get;syncstats[c]x]; date[x;c]'[d];
 {(` sv x,objname $[z in`edge`nav;`$string[z],"col";z])set y z}[x`db;c]'[key[c]except`stat];
 .sys.msg("ALG database end --"; datetag[x]d);
 if[x`main;exit 0]}

main:{
 .sys.banner"ALG database update";
  if[not first a:checkarg x; a:checkdate x];         /check args, if no error check date range
  if[first a; -2 a 1; $[x`main; exit 1; :()]];       /if error, exit or return to interactive session
 .sys.grid[x`tasks;8;x`main;dates;(x;last a)]}       /start grid of tasks, call 'dates' fn with args

if[x`main; main x]                                   /if main flag set, run main w'job args
