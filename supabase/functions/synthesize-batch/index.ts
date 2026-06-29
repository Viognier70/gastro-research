const SB_URL = Deno.env.get('SUPABASE_URL') || 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_ANON = Deno.env.get('SUPABASE_ANON_KEY') || ''
const CORS = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Content-Type':'application/json'}

const COMBOS = [
  ['sommelier','gastronomy'],['sommelier','multisensory'],['sommelier','sommellerie'],
  ['sommelier','flavor_science'],['sommelier','fermentation_science'],['sommelier','neurogastronomy'],
  ['sommelier','servicescape'],['sommelier','crossmodal'],
  ['chef','gastronomy'],['chef','culinary_science'],['chef','fermentation_science'],
  ['chef','neurogastronomy'],['chef','food_science'],
  ['fb_manager','gastronomy'],['fb_manager','servicescape'],['fb_manager','food_science'],
  ['researcher','gastronomy'],['researcher','multisensory'],['researcher','flavor_science'],
  ['researcher','nutritional_science'],['researcher','sensory_evaluation'],
]

Deno.serve(async (req) => {
  if(req.method==='OPTIONS') return new Response('ok',{headers:CORS})
  
  const results:{role:string,topic:string,status:string}[] = []
  
  for(const [role, topic] of COMBOS) {
    // Check if recent synthesis exists (less than 7 days old)
    const checkR = await fetch(`${SB_URL}/rest/v1/research_syntheses?role=eq.${role}&topic=eq.${topic}&order=created_at.desc&limit=1&select=created_at`,
      {headers:{'Authorization':`Bearer ${SB_ANON}`,'apikey':SB_ANON}})
    const existing = await checkR.json()
    if(Array.isArray(existing) && existing[0]) {
      const age = Date.now() - new Date(existing[0].created_at).getTime()
      if(age < 7*24*60*60*1000) {
        results.push({role,topic,status:'skipped_recent'})
        continue
      }
    }

    // Trigger synthesize
    const r = await fetch(`${SB_URL}/functions/v1/synthesize`, {
      method:'POST',
      headers:{'Authorization':`Bearer ${SB_ANON}`,'apikey':SB_ANON,'Content-Type':'application/json'},
      body:JSON.stringify({role,topic})
    })
    const d = await r.json()
    results.push({role,topic,status:d.ok?'created':d.error||'failed'})
    await new Promise(resolve=>setTimeout(resolve,500))
  }
  
  console.log('Batch done:', results.filter(r=>r.status==='created').length, 'created')
  return new Response(JSON.stringify({ok:true,results}),{headers:CORS})
})
