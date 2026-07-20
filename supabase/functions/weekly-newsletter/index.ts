import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const BREVO_KEY = Deno.env.get('BREVO_API_KEY') || ''
const SENDER_EMAIL = 'anders@crichton-fock.com'
const SENDER_NAME = 'Gusto Science'
const ADMIN_EMAIL = 'anders@crichton-fock.com'
const supabase = createClient(SB_URL, SB_KEY, { auth: { persistSession: false } })
const CORS = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Methods':'POST, OPTIONS','Access-Control-Allow-Headers':'Content-Type, Authorization'}
const ROLE_LABELS: Record<string,string> = {sommelier:'Sommelier',chef:'Chef',pastry_chef:'Pastry Chef',meal_creator:'Meal Creator',fb_manager:'F&B Manager',hotelier:'Hotelier',researcher:'Researcher',food_photographer:'Food Photographer'}
const ROLE_EMOJI: Record<string,string> = {sommelier:'🍷',chef:'👨‍🍳',pastry_chef:'🧁',meal_creator:'✨',fb_manager:'📊',hotelier:'🏨',researcher:'🔬',food_photographer:'📸'}
async function upsertBrevoContact(email: string, roles: string[]): Promise<boolean> {
  try {
    const resp = await fetch('https://api.brevo.com/v3/contacts', {method:'POST',headers:{'api-key':BREVO_KEY,'Content-Type':'application/json'},body:JSON.stringify({email,listIds:[BREVO_LIST_ID],attributes:{ROLES:roles.join(','),ROLE_PRIMARY:roles[0]||'',ROLE_COUNT:roles.length},updateEnabled:true})})
    const d = await resp.json()
    console.log('Brevo:', resp.status, d.message||d.id||'ok')
    return resp.status===201||resp.status===204||d.id>0
  } catch(e:any){console.log('Brevo error:',e.message);return false}
}
async function getArticlesForRole(roleKey: string, limit=4): Promise<any[]> {
  // Chip → science-namn. Före denna fix pekade colMap på ännu äldre kortare
  // legacy-varianter (meal_creator→'creator', fb_manager→'waiter') och resten
  // passerade rakt igenom som chip-slug. Alla dessa läste kolumner som
  // pipeline slutade fylla vid namnrymdsmigrationen 2026-07-12 — resultatet
  // var 0 artiklar för varje roll, tyst tomt. relevance_${col} var dessutom
  // äldre legacy (relevance_sci_ är rätt). Whitelist-mappen fungerar också
  // som injection-guard i .select().
  const colMap: Record<string,string> = {
    sommelier:           'sensory_pro',
    chef:                'culinary_pro',
    gastronomy:          'gastronomy_culture',
    meal_creator:        'gastronomy_culture',
    fb_manager:          'hospitality_mgmt',
    food_researcher:     'educator_researcher',
    researcher:          'educator_researcher',
    // Science-namn passar rakt igenom.
    sensory_pro:         'sensory_pro',
    culinary_pro:        'culinary_pro',
    gastronomy_culture:  'gastronomy_culture',
    hospitality_mgmt:    'hospitality_mgmt',
    educator_researcher: 'educator_researcher',
  }
  const col = colMap[roleKey]
  // Roller utanför Gustema-namnrymden (pastry_chef, hotelier, food_photographer
  // etc från ROLE_LABELS) har ingen Gustema-analys. Returnera [] tydligt
  // istället för att bygga en säker-men-tom SQL — och undvik injection-yta.
  if(!col) return []
  const oneWeekAgo = new Date(Date.now()-7*24*60*60*1000).toISOString()
  const {data,error} = await supabase.from('articles').select(`id,title,authors,journal,year,url,insight,topic,source_label,episteme_${col},techne_${col},phronesis_${col},relevance_sci_${col}`).gte('fetched_at',oneWeekAgo).not(`episteme_${col}`,'is',null).order(`relevance_sci_${col}`,{ascending:false}).limit(limit)
  if(error){ console.log('getArticlesForRole error:', roleKey, error.message); return [] }
  return (data||[]).map(a=>({...a,episteme:(a as any)[`episteme_${col}`],techne:(a as any)[`techne_${col}`],phronesis:(a as any)[`phronesis_${col}`]}))
}
function articleHTML(a: any): string {
  return `<div style="background:#fff;border:1px solid #e8e0d0;border-radius:10px;padding:20px;margin-bottom:16px"><p style="font-size:15px;font-weight:500;margin:0 0 8px;color:#0C0B09">${a.title||''}</p><p style="font-size:13px;color:#5C5649;line-height:1.6;margin:0 0 14px">${a.insight||''}</p>${a.episteme?`<div style="margin-bottom:10px"><div style="font-size:10px;font-weight:600;color:#1A3A5C;margin-bottom:5px">ε EPISTEME</div><p style="font-size:12px;color:#2A4A6C;line-height:1.6;margin:0;padding:10px;background:#E8EFF6;border-radius:6px">${a.episteme}</p></div>`:''}${a.techne?`<div style="margin-bottom:10px"><div style="font-size:10px;font-weight:600;color:#2D5016;margin-bottom:5px">τ TECHNE</div><p style="font-size:12px;color:#3A6020;line-height:1.6;margin:0;padding:10px;background:#EAF0E5;border-radius:6px">${a.techne}</p></div>`:''}${a.phronesis?`<div style="margin-bottom:10px"><div style="font-size:10px;font-weight:600;color:#5C2D00;margin-bottom:5px">φ PHRONESIS</div><p style="font-size:12px;color:#7A3D00;line-height:1.6;margin:0;padding:10px;background:#F5EDE3;border-radius:6px">${a.phronesis}</p></div>`:''}${a.url?`<a href="${a.url}" style="font-size:12px;color:#C9A84C;text-decoration:none;border:1px solid #C9A84C;padding:4px 14px;border-radius:20px">Read paper</a>`:''}</div>`
}
function buildEmail(roles: string[], byRole: Record<string,any[]>, weekStr: string): string {
  const total = Object.values(byRole).flat().length
  const sections = roles.map(role=>{const arts=byRole[role]||[];if(!arts.length)return '';return `<div style="margin-bottom:32px"><h2 style="font-size:16px;font-weight:500;color:#0C0B09;margin:0 0 16px;padding-bottom:10px;border-bottom:1px solid #E8E0D0">${ROLE_EMOJI[role]||''} ${ROLE_LABELS[role]||role}</h2>${arts.map(articleHTML).join('')}</div>`}).join('')
  return `<!DOCTYPE html><html><head><meta charset="utf-8"></head><body style="margin:0;padding:0;background:#F7F4ED;font-family:sans-serif"><div style="max-width:620px;margin:0 auto;padding:24px 16px"><div style="text-align:center;padding:32px 0 24px"><h1 style="font-size:28px;font-weight:400;color:#0C0B09;margin:0 0 6px;font-family:Georgia,serif">Gusto Science</h1><p style="font-size:13px;color:#9C9484;margin:0">Week of ${weekStr} · ${total} articles</p></div>${sections}<div style="text-align:center;padding:24px 0;border-top:1px solid #E8E0D0"><p style="font-size:12px;color:#9C9484;margin:0">Gusto Science · Dr. Anders Crichton-Fock</p><p style="font-size:12px;margin:8px 0 0"><a href="{{unsubscribeUrl}}" style="color:#9C9484">Unsubscribe</a></p></div></div></body></html>`
}
async function sendCampaign(roles: string[], html: string, weekStr: string, count: number) {
  const cd = await (await fetch('https://api.brevo.com/v3/emailCampaigns',{method:'POST',headers:{'api-key':BREVO_KEY,'Content-Type':'application/json'},body:JSON.stringify({name:`Gusto Science — Week of ${weekStr}`,subject:`${count} new articles — Gusto Science`,sender:{name:SENDER_NAME,email:SENDER_EMAIL},type:'classic',htmlContent:html,recipients:{listIds:[BREVO_LIST_ID]}})})).json()
  if(!cd.id)return{ok:false,error:cd}
  const send = await fetch(`https://api.brevo.com/v3/emailCampaigns/${cd.id}/sendNow`,{method:'POST',headers:{'api-key':BREVO_KEY,'Content-Type':'application/json'}})
  return{ok:send.ok,campaignId:cd.id}
}
async function sendAdminDigest(): Promise<boolean> {
  // Check if pipeline has stalled
  const {data:lastProcessed} = await supabase
    .from('processing_queue')
    .select('updated_at')
    .eq('status','done')
    .order('updated_at',{ascending:false})
    .limit(1)
    .single()
  const lastProcessedAt = lastProcessed?.updated_at ? new Date(lastProcessed.updated_at) : null
  const pipelineStalled = lastProcessedAt ? (Date.now() - lastProcessedAt.getTime()) > 30*60*1000 : true
  const minutesSinceLastProcessed = lastProcessedAt ? Math.round((Date.now()-lastProcessedAt.getTime())/60000) : null

  const [{count:total},{count:sciDone},{count:triadDone},{count:newToday}] = await Promise.all([
    supabase.from('articles').select('id',{count:'exact',head:true}),
    // sciDone: runSci skriver alla 5 relevance_sci_[science]-fält atomärt,
    // så vilket som helst av dem = alla. sensory_pro används som canary.
    // triadDone: phronesis_educator_researcher är sista fältet i labeled-prose-
    // formatet — samma strikta canary som screening_funnel-vyns triad_analyserade.
    supabase.from('articles').select('id',{count:'exact',head:true}).not('relevance_sci_sensory_pro','is',null),
    supabase.from('articles').select('id',{count:'exact',head:true}).not('phronesis_educator_researcher','is',null),
    supabase.from('articles').select('id',{count:'exact',head:true}).gte('fetched_at',new Date(Date.now()-24*60*60*1000).toISOString())
  ])
  const {data:pendingRoles} = await supabase.from('discovered_roles').select('role_key,role_label,article_count').eq('approved',false).order('article_count',{ascending:false}).limit(5)
  const sciPct = Math.round((sciDone||0)/(total||1)*100)
  const triadPct = Math.round((triadDone||0)/(total||1)*100)
  const html = `<!DOCTYPE html><html><body style="font-family:sans-serif;max-width:520px;margin:40px auto;padding:20px;background:#F7F4ED">
    <div style="background:#0C0B09;border-radius:10px;padding:20px 24px;margin-bottom:20px">
      <h2 style="color:#C9A84C;margin:0 0 4px;font-family:Georgia,serif">Gusto Science</h2>
      <p style="color:rgba(255,255,255,.6);margin:0;font-size:13px">Daily Admin Digest — ${new Date().toLocaleDateString('en-GB',{weekday:'long',day:'numeric',month:'long'})}</p>
    </div>
    <table style="width:100%;border-collapse:collapse;margin-bottom:20px;background:#fff;border-radius:10px;overflow:hidden;border:1px solid #e8e0d0">
      <tr style="background:#F7F4ED"><td style="padding:12px 16px;font-weight:500;font-size:13px">Total articles</td><td style="padding:12px 16px;text-align:right;font-size:15px;font-weight:600">${total?.toLocaleString()}</td></tr>
      <tr><td style="padding:12px 16px;font-weight:500;font-size:13px">New last 24h</td><td style="padding:12px 16px;text-align:right;font-size:15px;font-weight:600;color:${(newToday||0)>0?'#2D5016':'#999'}">${newToday}</td></tr>
      <tr style="background:#F7F4ED"><td style="padding:12px 16px;font-size:13px">Scientific relevance</td><td style="padding:12px 16px;text-align:right;font-size:13px">${sciDone?.toLocaleString()} / ${total?.toLocaleString()} <span style="color:#999">(${sciPct}%)</span></td></tr>
      <tr><td style="padding:12px 16px;font-size:13px">TRIAD enrichment</td><td style="padding:12px 16px;text-align:right;font-size:13px">${triadDone?.toLocaleString()} / ${total?.toLocaleString()} <span style="color:#999">(${triadPct}%)</span></td></tr>
      <tr style="background:#F7F4ED"><td style="padding:12px 16px;font-size:13px">Pending new roles</td><td style="padding:12px 16px;text-align:right;font-size:13px">${pendingRoles?.length||0}</td></tr>
    </table>
    ${pendingRoles?.length?`<div style="background:#fff;border:1px solid #e8e0d0;border-radius:10px;padding:16px;margin-bottom:20px"><p style="font-size:12px;font-weight:600;color:#5C5649;margin:0 0 8px">PENDING ROLES</p>${pendingRoles.map(r=>`<div style="font-size:13px;color:#0C0B09;padding:4px 0">${r.role_label} <span style="color:#9C9484">(${r.article_count} articles)</span></div>`).join('')}</div>`:''}
    ${pipelineStalled ? `<div style="background:#993C1D;border-radius:8px;padding:12px 16px;margin-bottom:16px"><p style="color:#fff;font-size:13px;font-weight:600;margin:0">⚠️ Pipeline stalled — last processed ${minutesSinceLastProcessed} minutes ago</p></div>` : ''}
    <p style="font-size:11px;color:#9C9484;text-align:center">gusto.science · automated status</p>
  </body></html>`
  const resp = await fetch('https://api.brevo.com/v3/smtp/email',{method:'POST',headers:{'api-key':BREVO_KEY,'Content-Type':'application/json'},body:JSON.stringify({sender:{name:SENDER_NAME,email:SENDER_EMAIL},to:[{email:ADMIN_EMAIL,name:'Anders'}],subject:`Gusto Science — ${newToday} new · ${sciPct}% sci · ${triadPct}% TRIAD`,htmlContent:html})})
  const d = await resp.json()
  console.log('Admin digest:', resp.status, d.messageId||d.message||'ok')
  return resp.ok
}
Deno.serve(async (req) => {
  if(req.method==='OPTIONS')return new Response(null,{headers:CORS})
  const body = await req.json().catch(()=>({}))
  const headers = {'Content-Type':'application/json',...CORS}
  if(body.admin_digest){
    const ok = await sendAdminDigest()
    return new Response(JSON.stringify({ok,action:'admin_digest'}),{headers})
  }
  if(body.subscribe && body.email){
    const roles: string[] = Array.isArray(body.roles)?body.roles:[body.role].filter(Boolean)
    if(!roles.length)roles.push('sommelier')
    console.log('Subscribe:',body.email,roles)
    const ok = await upsertBrevoContact(body.email,roles)
    return new Response(JSON.stringify({ok,action:'subscribed',roles}),{headers})
  }
  const roles = body.roles||Object.keys(ROLE_LABELS)
  const weekStr = new Date().toLocaleDateString('en-GB',{day:'numeric',month:'long',year:'numeric'})
  const byRole: Record<string,any[]> = {}
  let total = 0
  for(const role of roles){byRole[role]=await getArticlesForRole(role,4);total+=byRole[role].length}
  if(!total)return new Response(JSON.stringify({ok:false,reason:'No new articles'}),{headers})
  const result = await sendCampaign(roles,buildEmail(roles,byRole,weekStr),weekStr,total)
  console.log(`Newsletter sent: ${total} articles across ${roles.length} roles`)
  return new Response(JSON.stringify({ok:result.ok,campaignId:result.campaignId,articles:total}),{headers})
})
