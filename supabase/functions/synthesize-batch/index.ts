import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL         = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
const supabase = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } })
const CORS = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Content-Type':'application/json'}

// Alla roll-nycklar är science-namn. articles-tabellens episteme_<science>
// / relevance_sci_<science> är den enda sanningen efter roll-migrationen
// 2026-07-12; legacy chip-kolumner rörs inte längre av pipeline. Frontend
// (Syntheses-vyn) mappar sin chip-slug → science-namn för queryn mot
// research_syntheses.role.
const COMBOS: [string,string][] = [
  ['sensory_pro','gastronomy'],['sensory_pro','multisensory'],['sensory_pro','sommellerie'],
  ['sensory_pro','flavor_science'],['sensory_pro','fermentation_science'],['sensory_pro','neurogastronomy'],
  ['sensory_pro','servicescape'],['sensory_pro','crossmodal'],
  ['culinary_pro','gastronomy'],['culinary_pro','culinary_science'],['culinary_pro','fermentation_science'],
  ['culinary_pro','neurogastronomy'],['culinary_pro','food_science'],
  ['gastronomy_culture','gastronomy'],['gastronomy_culture','multisensory'],
  ['gastronomy_culture','crossmodal'],['gastronomy_culture','neurogastronomy'],
  ['hospitality_mgmt','gastronomy'],['hospitality_mgmt','servicescape'],['hospitality_mgmt','food_science'],
  ['educator_researcher','gastronomy'],['educator_researcher','multisensory'],['educator_researcher','flavor_science'],
  ['educator_researcher','nutritional_science'],['educator_researcher','sensory_evaluation'],
]

Deno.serve(async (req) => {
  if(req.method==='OPTIONS') return new Response('ok',{headers:CORS})

  const results: {role:string, topic:string, status:string}[] = []

  for(const [role, topic] of COMBOS) {
    // 7-dagars recency-check
    const { data: existing, error: checkErr } = await supabase
      .from('research_syntheses')
      .select('created_at,updated_at')
      .eq('role', role).eq('topic', topic)
      .order('updated_at', { ascending: false, nullsFirst: false })
      .limit(1)

    if(checkErr) {
      results.push({role,topic,status:'check_failed:'+checkErr.message})
      continue
    }
    if(Array.isArray(existing) && existing[0]) {
      const last = new Date(existing[0].updated_at || existing[0].created_at).getTime()
      if(Date.now() - last < 7*24*60*60*1000) {
        results.push({role,topic,status:'skipped_recent'})
        continue
      }
    }

    // Fn-to-fn invoke — kräver giltig JWT. SERVICE_ROLE_KEY signeras av
    // samma nyckel som verify_jwt validerar mot, så den släpps in.
    const r = await fetch(`${SB_URL}/functions/v1/synthesize`, {
      method:'POST',
      headers:{
        'Authorization': `Bearer ${SB_SERVICE_KEY}`,
        'apikey': SB_SERVICE_KEY,
        'Content-Type':'application/json'
      },
      body: JSON.stringify({role, topic})
    })
    const d = await r.json().catch(()=>({error:'invalid_json'}))
    results.push({role, topic, status: d.ok ? 'created' : (d.error || `http_${r.status}`)})
    await new Promise(resolve => setTimeout(resolve, 500))
  }

  const created = results.filter(r => r.status === 'created').length
  console.log('Batch done:', created, 'created,', results.length - created, 'other')
  return new Response(JSON.stringify({ok:true, created, results}), {headers:CORS})
})
