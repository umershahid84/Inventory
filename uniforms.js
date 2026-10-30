// Uniform Supplies (administrators only).
// Uses helpers defined in index.html: sb, rpc, $, esc, ico, empty, banner, errText, fmt, doPrint, show.
// Database objects come from supabase/uniforms.sql.

const U={loaded:false,lines:[],roles:[],variants:[],stock:[],emps:[],open:[],
  view:"stock",lineFilter:"all",empFilter:{q:"",line:"all",status:"active",owing:false},curId:null,curIssues:[]};

// ---------- loading ----------
async function fetchAll(build){
  let all=[],from=0;
  for(;;){const {data,error}=await build().range(from,from+999);if(error)throw error;all=all.concat(data);if(data.length<1000)return all;from+=1000}
}
async function loadU(){
  const [lines,roles,variants,stock,emps,open]=await Promise.all([
    fetchAll(()=>sb.from("uniform_lines").select("*").order("sort")),
    fetchAll(()=>sb.from("uniform_roles").select("*").order("name")),
    fetchAll(()=>sb.from("uniform_variants").select("*").order("sort")),
    fetchAll(()=>sb.from("uniform_stock").select("*").order("line_code").order("variant_id")),
    fetchAll(()=>sb.from("uniform_employees").select("*").order("full_name")),
    fetchAll(()=>sb.from("uniform_issues").select("*").gt("outstanding",0).order("id"))]);
  Object.assign(U,{lines,roles,variants,stock,emps,open,loaded:true});
}
const missingTables=e=>e&&(/PGRST205|42P01/.test(e.code||"")||/does not exist|schema cache|Could not find the table/i.test(e.message||""));

async function uniformEnter(){
  const body=$("uniformBody");
  body.innerHTML=`<div class="card"><div class="bd mute">Loading…</div></div>`;
  try{await loadU()}
  catch(x){
    body.innerHTML=missingTables(x)
      ?`<div class="card"><div class="bd"><h2>One more setup step</h2><p>The uniform tables are not in your database yet. In Supabase open <b>SQL Editor → New query</b>, paste the contents of <code>supabase/uniforms.sql</code> from the repository, and click <b>Run</b>. Then reload this page.</p></div></div>`
      :`<div class="card"><div class="bd"><div class="autherr">${esc(errText(x))}</div></div></div>`;
    return;
  }
  banner("");renderU();
}
async function reloadU(){await loadU();if(U.view==="detail")await loadCur();}

// ---------- helpers ----------
const FITS=["Men","Women","Unisex"];
const lineName=c=>(U.lines.find(l=>l.code===c)||{}).name||c;
const lineSort=c=>(U.lines.find(l=>l.code===c)||{sort:99}).sort;
const vById=id=>U.variants.find(v=>v.id===id)||{garment:"?",fit:"",size:"",sort:0};
const vLabel=v=>`${v.garment} · ${v.fit} · ${v.size}`;
const rolesOf=l=>U.roles.filter(r=>r.line_code===l).map(r=>r.name);
function garmentList(){const m=new Map();U.variants.forEach(v=>{if(!m.has(v.garment))m.set(v.garment,v.sort)});return [...m].sort((a,b)=>a[1]-b[1]).map(x=>x[0])}
function fitList(g){const s=[];U.variants.filter(v=>v.garment===g).sort((a,b)=>a.sort-b.sort).forEach(v=>{if(!s.includes(v.fit))s.push(v.fit)});return s}
const sizeList=(g,f)=>U.variants.filter(v=>v.garment===g&&v.fit===f).sort((a,b)=>a.sort-b.sort);
const lineOptions=(sel,all)=>(all?`<option value="all">All lines of business</option>`:"")+U.lines.map(l=>`<option value="${l.code}"${l.code===sel?" selected":""}>${esc(l.name)}</option>`).join("");

// Garment → Fit → Size drop-downs that follow each other.
function pickerHTML(p){return `<div><label for="${p}G">Garment</label><select id="${p}G"></select></div><div><label for="${p}F">Fit</label><select id="${p}F"></select></div><div><label for="${p}S">Size</label><select id="${p}S"></select></div>`}
function wirePicker(p){
  const G=$(p+"G"),F=$(p+"F"),S=$(p+"S");
  const fillS=()=>{S.innerHTML=sizeList(G.value,F.value).map(v=>`<option value="${v.id}">${esc(v.size)}</option>`).join("")};
  const fillF=()=>{F.innerHTML=fitList(G.value).map(f=>`<option>${esc(f)}</option>`).join("");fillS()};
  G.innerHTML=garmentList().map(g=>`<option>${esc(g)}</option>`).join("");
  G.onchange=fillF;F.onchange=fillS;fillF();
}
const picked=p=>parseInt($(p+"S").value,10);
function wireRoles(lineSel,roleSel,cur){
  const fill=()=>{$(roleSel).innerHTML=rolesOf($(lineSel).value).map(r=>`<option${r===cur?" selected":""}>${esc(r)}</option>`).join("")};
  $(lineSel).onchange=()=>{cur=null;fill()};fill();
}
function modal(title,body,onSubmit,okText){
  const m=document.createElement("div");m.className="modalbg";
  m.innerHTML=`<form class="modal"><h2>${title}</h2>${body}<div class="acts" style="margin-top:18px;justify-content:flex-end"><button type="button" class="btn sec" data-x>Cancel</button><button class="btn" type="submit">${okText||"Save"}</button></div></form>`;
  document.body.appendChild(m);const f=m.firstElementChild;
  m.querySelector("[data-x]").onclick=()=>m.remove();
  f.onsubmit=async e=>{e.preventDefault();const b=f.querySelector("button[type=submit]");b.disabled=true;
    try{await onSubmit(f);m.remove()}catch(x){alert(errText(x));b.disabled=false}};
  const first=f.querySelector("input,select");if(first)first.focus();return m;
}
const heldBy=id=>U.open.filter(i=>i.employee_id===id).reduce((a,i)=>a+i.outstanding,0);
const empLine=e=>`${esc(lineName(e.line_code))} · ${esc(e.role)}`;

// ---------- shell ----------
function renderU(){
  const body=$("uniformBody");
  const tabs=`<div class="tabs2" style="max-width:360px"><button data-uv="stock" class="${U.view==="stock"?"on":""}">Stock</button><button data-uv="emps" class="${U.view!=="stock"?"on":""}">Employees</button></div>`;
  if(U.view==="stock"){
    body.innerHTML=tabs+`
    <div class="card"><div class="hd"><div><h2>Receive uniform stock</h2><p>Stock is kept separately for each line of business.</p></div></div>
      <div class="bd"><form id="uStockForm" class="row">
        <div><label for="usLine">Line of business</label><select id="usLine">${lineOptions()}</select></div>
        ${pickerHTML("us")}
        <div style="flex:0 0 100px;min-width:90px"><label for="usQty">Quantity</label><input id="usQty" type="number" min="1" step="1" value="1" required></div>
        <div style="flex:0 0 auto"><button class="btn" type="submit"><svg class="i"><use href="#i-plus"/></svg>Add stock</button></div>
      </form></div>
      <div class="hint"><details><summary style="cursor:pointer;font-weight:600">A size is missing from the lists? Add it</summary>
        <form id="uVarForm" class="row" style="margin-top:10px">
          <div><label for="uvG">Garment</label><input id="uvG" type="text" list="uvGl" required placeholder="e.g. Pants"><datalist id="uvGl">${garmentList().map(g=>`<option value="${esc(g)}">`).join("")}</datalist></div>
          <div><label for="uvF">Fit</label><select id="uvF">${FITS.map(f=>`<option>${f}</option>`).join("")}</select></div>
          <div><label for="uvS">Size</label><input id="uvS" type="text" required placeholder="e.g. 32x30"></div>
          <div style="flex:0 0 auto"><button class="btn sec" type="submit">Add size</button></div>
        </form></details></div></div>
    <div class="card"><div class="hd"><div class="acts" id="uLineFilter"></div><button class="btn sec" id="uPrintOrder"><svg class="i"><use href="#i-print"/></svg>Print uniform order list</button></div>
      <div class="scroll" id="uStockTable"></div></div>`;
    wirePicker("us");renderUStock();
    $("uStockForm").onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector("button");b.disabled=true;
      try{await rpc("uniform_add_stock",{p_line:$("usLine").value,p_variant:picked("us"),p_qty:parseInt($("usQty").value,10)});
        banner("");await reloadU();renderUStock();$("usQty").value=1;}
      catch(x){banner("Not saved: "+errText(x))}b.disabled=false};
    $("uVarForm").onsubmit=async e=>{e.preventDefault();
      try{await rpc("uniform_add_variant",{p_garment:$("uvG").value,p_fit:$("uvF").value,p_size:$("uvS").value});
        banner("");await reloadU();renderU();}
      catch(x){banner("Not saved: "+errText(x))}};
    $("uPrintOrder").onclick=printUOrder;
  }else if(U.view==="emps"){
    const f=U.empFilter;
    body.innerHTML=tabs+`
    <div class="card"><div class="hd"><div><h2>Add an employee</h2><p>Choose the line of business, then the job.</p></div></div>
      <div class="bd"><form id="uEmpForm" class="row">
        <div style="flex:0 0 130px;min-width:110px"><label for="ueNo">Employee # (optional)</label><input id="ueNo" type="text" autocomplete="off"></div>
        <div style="flex:2"><label for="ueName">Full name</label><input id="ueName" type="text" autocomplete="off" required></div>
        <div><label for="ueLine">Line of business</label><select id="ueLine">${lineOptions()}</select></div>
        <div><label for="ueRole">Job</label><select id="ueRole"></select></div>
        <div style="flex:0 0 auto"><button class="btn" type="submit"><svg class="i"><use href="#i-plus"/></svg>Add employee</button></div>
      </form></div></div>
    <div id="uAlert"></div>
    <div class="card"><div class="hd"><div class="row" style="flex:1;align-items:center">
        <div style="min-width:200px"><input id="ufQ" type="text" placeholder="Search name or employee #…" value="${esc(f.q)}"></div>
        <div style="flex:0 0 200px"><select id="ufLine">${lineOptions(f.line,true)}</select></div>
        <div style="flex:0 0 150px"><select id="ufStatus"><option value="active">Active</option><option value="terminated">Terminated</option><option value="all">All</option></select></div>
        <label style="display:flex;gap:6px;align-items:center;margin:0;flex:0 0 auto;font-weight:500"><input type="checkbox" id="ufOwing"${f.owing?" checked":""}> Holding items</label></div>
        <button class="btn sec" id="uPrintCollect"><svg class="i"><use href="#i-print"/></svg>Print collection list</button></div>
      <div class="scroll" id="uEmpTable"></div></div>`;
    $("ufStatus").value=f.status;
    wireRoles("ueLine","ueRole");renderUEmps();
    $("uEmpForm").onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector("button");b.disabled=true;
      try{const id=await rpc("uniform_add_employee",{p_emp_no:$("ueNo").value,p_name:$("ueName").value,p_line:$("ueLine").value,p_role:$("ueRole").value});
        banner("");await reloadU();openEmp(id);return}
      catch(x){banner("Not saved: "+errText(x))}b.disabled=false};
    const upd=()=>{Object.assign(U.empFilter,{q:$("ufQ").value,line:$("ufLine").value,status:$("ufStatus").value,owing:$("ufOwing").checked});renderUEmps()};
    ["ufQ","ufLine","ufStatus","ufOwing"].forEach(id=>$(id).oninput=upd);
    $("uPrintCollect").onclick=printCollectionList;
  }else{renderUDetail()}
  document.querySelectorAll("[data-uv]").forEach(b=>b.onclick=()=>{U.view=b.dataset.uv;renderU()});
}

// ---------- stock table ----------
function renderUStock(){
  $("uLineFilter").innerHTML=[["all","All"],...U.lines.map(l=>[l.code,l.name])].map(([c,n])=>`<button class="btn sm ${U.lineFilter===c?"":"sec"}" data-l="${c}">${esc(n)}</button>`).join("");
  $("uLineFilter").onclick=e=>{const b=e.target.closest("[data-l]");if(b){U.lineFilter=b.dataset.l;renderUStock()}};
  const rows=U.stock.filter(s=>U.lineFilter==="all"||s.line_code===U.lineFilter)
    .sort((a,b)=>lineSort(a.line_code)-lineSort(b.line_code)||vById(a.variant_id).sort-vById(b.variant_id).sort);
  $("uStockTable").innerHTML=rows.length?`<table><thead><tr><th>Line of business</th><th>Garment</th><th>Fit</th><th>Size</th><th>In stock</th><th>Status</th><th class="adm"></th></tr></thead><tbody>${rows.map(s=>{
    const v=vById(s.variant_id),low=s.qty<=0||s.qty*4<=s.baseline,pct=s.baseline>0?Math.min(100,s.qty/s.baseline*100):0;
    return `<tr class="${low?"low":""}"><td>${esc(lineName(s.line_code))}</td><td class="name">${esc(v.garment)}</td><td>${esc(v.fit)}</td><td><b>${esc(v.size)}</b></td>
    <td><span class="qty">${s.qty}</span> <span style="color:var(--mute)">/ ${s.baseline}</span><div class="meter"><i style="width:${pct}%"></i></div></td>
    <td>${s.qty<=0?'<span class="pill out">Out</span>':low?'<span class="pill low">Low – order</span>':'<span class="pill ok">In stock</span>'}</td>
    <td><div class="acts"><button class="btn sm sec" data-fix="${s.line_code}|${s.variant_id}">Correct</button></div></td></tr>`}).join("")}</tbody></table><div class="hint">Only sizes that have been received appear here. Items turn red at ¼ of the amount last received.</div>`
    :empty("No uniform stock yet – receive some above.");
  $("uStockTable").onclick=async e=>{
    const b=e.target.closest("[data-fix]");if(!b)return;const [line,vid]=b.dataset.fix.split("|");
    const s=U.stock.find(x=>x.line_code===line&&x.variant_id==vid);
    const n=parseInt(prompt(`Correct the count for ${vLabel(vById(+vid))} (${lineName(line)}). Currently ${s.qty}:`,s.qty),10);
    if(!(n>=0))return;
    try{await rpc("uniform_correct_stock",{p_line:line,p_variant:+vid,p_qty:n});banner("");await reloadU();renderUStock()}
    catch(x){banner("Not saved: "+errText(x))}
  };
}
function printUOrder(){
  const low=U.stock.filter(s=>s.qty<=0||s.qty*4<=s.baseline).sort((a,b)=>lineSort(a.line_code)-lineSort(b.line_code)||vById(a.variant_id).sort-vById(b.variant_id).sort);
  if(!low.length)return alert("No uniform sizes need ordering right now.");
  doPrint(`<div style="font-family:sans-serif"><h1 style="font-size:20px">Uniform order list</h1><p>${new Date().toLocaleString()} – ${low.length} size(s) at or below ¼ of the amount last received</p>
  <table><thead><tr><th>Line of business</th><th>Garment</th><th>Fit</th><th>Size</th><th>In stock</th><th>Last received</th><th>Suggested order</th></tr></thead><tbody>${low.map(s=>{const v=vById(s.variant_id);
  return `<tr><td>${esc(lineName(s.line_code))}</td><td>${esc(v.garment)}</td><td>${esc(v.fit)}</td><td>${esc(v.size)}</td><td>${s.qty}</td><td>${s.baseline}</td><td><b>${Math.max(s.baseline-s.qty,1)}</b></td></tr>`}).join("")}</tbody></table></div>`);
}

// ---------- employees list ----------
function filteredEmps(){
  const f=U.empFilter,q=f.q.trim().toLowerCase();
  return U.emps.filter(e=>(f.status==="all"||e.status===f.status)&&(f.line==="all"||e.line_code===f.line)&&
    (!q||e.full_name.toLowerCase().includes(q)||(e.emp_no||"").toLowerCase().includes(q))&&(!f.owing||heldBy(e.id)>0));
}
function renderUEmps(){
  const owingTerm=U.emps.filter(e=>e.status==="terminated"&&heldBy(e.id)>0);
  $("uAlert").innerHTML=owingTerm.length?`<div class="card" style="border-color:var(--redline);background:var(--redbg)"><div class="bd" style="display:flex;gap:12px;align-items:center;flex-wrap:wrap;color:#991b1b"><b>${owingTerm.length} terminated employee${owingTerm.length>1?"s":""} still ${owingTerm.length>1?"hold":"holds"} uniform items.</b><button class="btn sm danger" id="uShowTerm">Show them</button></div></div>`:"";
  if($("uShowTerm"))$("uShowTerm").onclick=()=>{Object.assign(U.empFilter,{status:"terminated",owing:true,line:"all",q:""});renderU()};
  const list=filteredEmps();
  $("uEmpTable").innerHTML=list.length?`<table><thead><tr><th>Name</th><th>Emp #</th><th>Line of business · Job</th><th>Status</th><th>Items held</th><th></th></tr></thead><tbody>${list.map(e=>{
    const n=heldBy(e.id),term=e.status==="terminated";
    return `<tr class="${term&&n?"low":""}"><td class="name">${esc(e.full_name)}</td><td>${esc(e.emp_no||"")}</td><td>${empLine(e)}</td>
    <td>${term?'<span class="pill out">Terminated</span>':'<span class="pill ok">Active</span>'}</td><td><span class="qty">${n}</span></td>
    <td><div class="acts"><button class="btn sm" data-open="${e.id}">Open / report</button></div></td></tr>`}).join("")}</tbody></table>`
    :empty(U.emps.length?"No employees match these filters.":"No employees yet – add the first one above.");
  $("uEmpTable").onclick=e=>{const b=e.target.closest("[data-open]");if(b)openEmp(b.dataset.open)};
}

// ---------- one employee ----------
async function loadCur(){
  const {data,error}=await sb.from("uniform_issues").select("*").eq("employee_id",U.curId).order("id",{ascending:false});
  if(error)throw error;U.curIssues=data;
}
async function openEmp(id){U.curId=id;U.view="detail";try{await loadCur()}catch(x){banner(errText(x));return}renderU()}
function renderUDetail(){
  const e=U.emps.find(x=>x.id===U.curId);if(!e){U.view="emps";return renderU()}
  const term=e.status==="terminated",held=U.curIssues.filter(i=>i.outstanding>0),units=held.reduce((a,i)=>a+i.outstanding,0);
  const hist=U.curIssues.filter(i=>i.returned_qty>0||i.discarded_qty>0);
  $("uniformBody").innerHTML=`
  <button class="btn sec sm" id="uBack" style="margin-bottom:12px">← All employees</button>
  <div class="card"><div class="hd"><div><h2 style="font-size:18px">${esc(e.full_name)} ${term?'<span class="pill out">Terminated</span>':'<span class="pill ok">Active</span>'}</h2>
    <p>${e.emp_no?`Employee # ${esc(e.emp_no)} · `:""}${empLine(e)}${term&&e.terminated_on?` · terminated ${esc(e.terminated_on)}`:""}</p></div>
    <div class="acts"><button class="btn" id="uPrintEmp"><svg class="i"><use href="#i-print"/></svg>Print report</button>
      <button class="btn sec" id="uEditEmp">Edit</button>
      <button class="btn ${term?"sec":"danger"}" id="uTerm">${term?"Reactivate":"Mark as terminated"}</button></div></div>
    <div class="bd" style="padding:14px 20px"><b style="font-size:20px">${units}</b> <span class="mute">item${units===1?"":"s"} currently held${term&&units?" – <b style='color:var(--red)'>to be collected</b>":""}</span></div></div>
  ${term?"":`<div class="card"><div class="hd"><div><h2>Issue uniform</h2><p>Takes it out of ${esc(lineName(e.line_code))} stock. Tick “record only” for items they already had before this system.</p></div></div>
    <div class="bd"><form id="uIssueForm" class="row">${pickerHTML("ui")}
      <div style="flex:0 0 90px;min-width:80px"><label for="uiQty">Qty</label><input id="uiQty" type="number" min="1" value="1" required></div>
      <div style="flex:2"><label for="uiNote">Note (optional)</label><input id="uiNote" type="text" autocomplete="off"></div>
      <label style="display:flex;gap:6px;align-items:center;margin:0 0 10px;flex:0 0 auto;font-weight:500"><input type="checkbox" id="uiRec"> Record only (don't deduct stock)</label>
      <div style="flex:0 0 auto"><button class="btn" type="submit">Issue</button></div></form></div></div>`}
  <div class="card"><div class="hd"><h2>Currently assigned</h2></div><div class="scroll">${held.length?`<table><thead><tr><th>Issued</th><th>Item</th><th>Issued</th><th>Still held</th><th>Note</th><th>By</th><th></th></tr></thead><tbody>${held.map(i=>`<tr><td>${fmt(i.issued_at)}</td><td class="name">${esc(vLabel(vById(i.variant_id)))}</td><td>${i.qty}</td><td><span class="qty">${i.outstanding}</span></td><td>${esc(i.note||"")}${i.from_stock?"":' <span class="mute">(record only)</span>'}</td><td>${esc(i.issued_by||"")}</td>
    <td><div class="acts"><button class="btn sm" data-ret="${i.id}">Return</button>${i.returned_qty+i.discarded_qty===0?`<button class="btn sm sec" data-void="${i.id}">Undo</button>`:""}</div></td></tr>`).join("")}</tbody></table>`:empty("Nothing is assigned to this employee.")}</div></div>
  ${hist.length?`<div class="card"><div class="hd"><h2>Returned items</h2></div><div class="scroll"><table><thead><tr><th>Issued</th><th>Item</th><th>Issued</th><th>Back in stock</th><th>Lost / discarded</th><th>Closed</th></tr></thead><tbody>${hist.map(i=>`<tr><td>${fmt(i.issued_at)}</td><td class="name">${esc(vLabel(vById(i.variant_id)))}</td><td>${i.qty}</td><td>${i.returned_qty}</td><td>${i.discarded_qty}</td><td>${i.closed_at?fmt(i.closed_at):'<span class="mute">partly</span>'}</td></tr>`).join("")}</tbody></table></div></div>`:""}`;
  $("uBack").onclick=()=>{U.view="emps";renderU()};
  $("uPrintEmp").onclick=()=>printEmployee(e);
  $("uEditEmp").onclick=()=>{
    modal("Edit employee",`<div class="f"><label>Employee #</label><input name="no" type="text" value="${esc(e.emp_no||"")}"></div>
    <div class="f"><label>Full name</label><input name="nm" type="text" value="${esc(e.full_name)}" required></div>
    <div class="f"><label>Line of business</label><select id="emL">${lineOptions(e.line_code)}</select></div>
    <div class="f"><label>Job</label><select id="emR"></select></div>`,
    async f=>{await rpc("uniform_update_employee",{p_id:e.id,p_emp_no:f.no.value,p_name:f.nm.value,p_line:$("emL").value,p_role:$("emR").value});await reloadU();renderU()});
    wireRoles("emL","emR",e.role);
  };
  $("uTerm").onclick=async()=>{
    const msg=term?`Reactivate ${e.full_name}?`:`Mark ${e.full_name} as terminated?${units?`\n\nThey still hold ${units} item(s) – print the report and collect them.`:""}`;
    if(!confirm(msg))return;
    try{await rpc("uniform_set_status",{p_id:e.id,p_terminated:!term});banner("");await reloadU();renderU()}catch(x){banner("Not saved: "+errText(x))}
  };
  if($("uIssueForm")){wirePicker("ui");$("uIssueForm").onsubmit=async ev=>{ev.preventDefault();const b=ev.target.querySelector("button");b.disabled=true;
    try{await rpc("uniform_issue",{p_employee:e.id,p_variant:picked("ui"),p_qty:parseInt($("uiQty").value,10),p_note:$("uiNote").value,p_from_stock:!$("uiRec").checked});
      banner("");await reloadU();renderU()}catch(x){banner("Not saved: "+errText(x));b.disabled=false}}}
  document.querySelectorAll("[data-ret]").forEach(b=>b.onclick=()=>{
    const i=U.curIssues.find(x=>x.id==b.dataset.ret);
    modal(`Return: ${esc(vLabel(vById(i.variant_id)))}`,`<p class="mute" style="margin:0 0 12px">${esc(e.full_name)} holds <b>${i.outstanding}</b> of these.</p>
      <div class="f"><label>Returned – goes back into stock</label><input name="back" type="number" min="0" max="${i.outstanding}" value="${i.outstanding}" required></div>
      <div class="f"><label>Not returned – lost / damaged / thrown away</label><input name="dis" type="number" min="0" max="${i.outstanding}" value="0" required></div>
      <div class="f"><label>Note (optional)</label><input name="note" type="text" autocomplete="off"></div>`,
      async f=>{await rpc("uniform_return",{p_issue:i.id,p_back:parseInt(f.back.value,10),p_discard:parseInt(f.dis.value,10),p_note:f.note.value});await reloadU();renderU()},"Record return");
  });
  document.querySelectorAll("[data-void]").forEach(b=>b.onclick=async()=>{
    const i=U.curIssues.find(x=>x.id==b.dataset.void);
    if(!confirm(`Undo this issue of ${i.qty} × ${vLabel(vById(i.variant_id))}?${i.from_stock?" The items go back into stock.":""}`))return;
    try{await rpc("uniform_void_issue",{p_issue:i.id});banner("");await reloadU();renderU()}catch(x){banner("Not saved: "+errText(x))}
  });
}

// ---------- reports ----------
const sigStyle='style="margin-top:34px;display:flex;gap:40px;font-family:sans-serif"';
function printEmployee(e){
  const held=U.curIssues.filter(i=>i.outstanding>0),units=held.reduce((a,i)=>a+i.outstanding,0),term=e.status==="terminated";
  doPrint(`<div style="font-family:sans-serif"><h1 style="font-size:20px;margin:0 0 4px">Uniform assignment report</h1>
  <p style="margin:0 0 14px">Printed ${new Date().toLocaleString()}</p>
  <table style="margin-bottom:18px"><tbody>
    <tr><td><b>Employee</b></td><td>${esc(e.full_name)}</td><td><b>Employee #</b></td><td>${esc(e.emp_no||"–")}</td></tr>
    <tr><td><b>Line of business</b></td><td>${esc(lineName(e.line_code))}</td><td><b>Job</b></td><td>${esc(e.role)}</td></tr>
    <tr><td><b>Status</b></td><td>${term?"TERMINATED"+(e.terminated_on?" "+esc(e.terminated_on):""):"Active"}</td><td><b>Items held</b></td><td>${units}</td></tr></tbody></table>
  <h2 style="font-size:16px">${term?"Items to collect":"Items currently assigned"}</h2>
  ${held.length?`<table><thead><tr><th>Garment</th><th>Fit</th><th>Size</th><th>Qty held</th><th>Issued</th><th>Note</th><th>Collected</th></tr></thead><tbody>${held.map(i=>{const v=vById(i.variant_id);
    return `<tr><td>${esc(v.garment)}</td><td>${esc(v.fit)}</td><td>${esc(v.size)}</td><td>${i.outstanding}</td><td>${new Date(i.issued_at).toLocaleDateString()}</td><td>${esc(i.note||"")}</td><td>☐ ____</td></tr>`}).join("")}</tbody></table>`:"<p>No uniform items are assigned to this employee.</p>"}
  <div ${sigStyle}><div>Employee signature: ______________________</div><div>Date: ______________</div></div>
  <div ${sigStyle}><div>Received by: ______________________</div><div>Date: ______________</div></div></div>`);
}
function printCollectionList(){
  const emps=U.emps.filter(e=>e.status==="terminated"&&heldBy(e.id)>0);
  if(!emps.length)return alert("No terminated employees are holding uniform items.");
  doPrint(`<div style="font-family:sans-serif"><h1 style="font-size:20px">Uniforms to collect – terminated employees</h1><p>${new Date().toLocaleString()}</p>
  ${emps.map(e=>`<h2 style="font-size:15px;margin:18px 0 4px">${esc(e.full_name)}${e.emp_no?` (#${esc(e.emp_no)})`:""} – ${empLine(e)}</h2>
  <table><thead><tr><th>Garment</th><th>Fit</th><th>Size</th><th>Qty held</th><th>Collected</th></tr></thead><tbody>${U.open.filter(i=>i.employee_id===e.id).map(i=>{const v=vById(i.variant_id);
    return `<tr><td>${esc(v.garment)}</td><td>${esc(v.fit)}</td><td>${esc(v.size)}</td><td>${i.outstanding}</td><td>☐ ____</td></tr>`}).join("")}</tbody></table>`).join("")}</div>`);
}
