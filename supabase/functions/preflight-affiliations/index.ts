// preflight-affiliations — one-shot test for the B (backfill) strategy.
//
// Goal: verify that OpenAlex has affiliation data for a known-good set of
// articles (Anders' own 20 publications) BEFORE we commit to building the
// full backfill-affiliations fn against 267k rows.
//
// Uses the EXACT same OpenAlex extraction logic that daily-fetch's A-fix
// (commit 3a93f68) applies. If this preflight fills the missing Scopus /
// PubMed / endnote rows correctly, the full backfill can safely reuse
// the same code path.
//
// Deploy: supabase functions deploy preflight-affiliations --no-verify-jwt
// Trigger: curl -X POST https://igmkzhdovyhbfgjomrsc.supabase.co/functions/v1/preflight-affiliations
// Delete after use: supabase functions delete preflight-affiliations

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SB_URL = 'https://igmkzhdovyhbfgjomrsc.supabase.co'
const SB_SERVICE_KEY = Deno.env.get('SERVICE_ROLE_KEY') || ''
const CORS = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' }

// Author-surname filters that match Anders' 20 known publications
// (Herdenstam is his pre-2015 surname, Crichton-Fock post-2015).
// Using '-Fock' guarantees no false positives on other "Crichton"s.
const AUTHOR_FILTERS = ['Crichton-Fock', 'Herdenstam']

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (!SB_SERVICE_KEY) {
    return json({ error: 'SERVICE_ROLE_KEY missing from env' }, 500)
  }

  const supabase = createClient(SB_URL, SB_SERVICE_KEY)

  // 1. Select target articles from the base articles table (writable).
  const orFilter = AUTHOR_FILTERS.map(a => `authors.ilike.*${a}*`).join(',')
  const { data: articles, error: selErr } = await supabase
    .from('articles')
    .select('id, year, source, title, authors, journal, url, primary_institution, affiliations, institutions')
    .or(orFilter)
    .order('year', { ascending: false })

  if (selErr) return json({ error: 'select_failed', message: selErr.message }, 500)

  const report: any[] = []
  for (const art of (articles || [])) {
    const rec: any = {
      id: art.id,
      year: art.year,
      source: art.source,
      title: (art.title || '').slice(0, 90),
      authors: (art.authors || '').slice(0, 90),
      before: {
        primary_institution: art.primary_institution,
        institutions: art.institutions,
        affiliations: art.affiliations
      },
      doi: null,
      openalex_status: null,
      openalex_found_institutions: null,
      action: null
    }

    // 2. Extract DOI. Same regex as daily-fetch expects — matches 10.NNNN/…
    const doi = extractDoi(art.url || '')
    rec.doi = doi

    if (!doi) {
      rec.action = 'skipped_no_doi'
      report.push(rec)
      continue
    }

    // 3. OpenAlex lookup, authorships-only for speed
    const oa = await fetchOpenAlex(doi)
    rec.openalex_status = oa.status

    if (!oa.ok) {
      rec.action = `openalex_${oa.status}`
      report.push(rec)
      continue
    }

    // 4. Derive fields — SAME logic as daily-fetch A-fix
    const authorships = oa.data.authorships || []
    const flatInsts = authorships.flatMap((a: any) => a.institutions || [])
    const institutions = [...new Set(
      flatInsts.map((i: any) => i.display_name).filter(Boolean)
    )] as string[]
    const institution_coords = flatInsts
      .filter((i: any) => i.geo?.latitude)
      .map((i: any) => ({
        name: i.display_name, lat: i.geo.latitude, lng: i.geo.longitude, country: i.country_code
      }))
      .filter((v: any, i: number, a: any[]) => a.findIndex((x: any) => x.name === v.name) === i)
    const countries = [...new Set(
      flatInsts.map((i: any) => i.country_code).filter(Boolean)
    )] as string[]
    const affiliations = [...new Set(
      authorships.flatMap((a: any) => a.raw_affiliation_strings || []).filter(Boolean)
    )] as string[]
    const primary_institution = institutions[0] || null

    rec.openalex_found_institutions = institutions

    if (!institutions.length) {
      rec.action = 'openalex_ok_no_institutions'
      report.push(rec)
      continue
    }

    // 5. Build update payload. Only fill fields we have non-null data for.
    // Preserve existing primary_institution if it was already set — trust
    // the previous enrichment over a fresh guess.
    const update: any = {
      institutions,
      affiliations: affiliations.length ? affiliations : null
    }
    if (institution_coords.length) update.institution_coords = institution_coords
    if (!art.primary_institution) update.primary_institution = primary_institution
    if (countries.length) {
      update.country = countries[0]
      update.countries = countries
    }

    const { error: updErr } = await supabase
      .from('articles')
      .update(update)
      .eq('id', art.id)

    if (updErr) {
      rec.action = 'update_failed'
      rec.update_error = updErr.message
    } else {
      rec.action = 'updated'
      rec.after = {
        primary_institution: update.primary_institution || art.primary_institution,
        institutions: update.institutions,
        affiliations: update.affiliations
      }
    }
    report.push(rec)

    // Politeness delay for OpenAlex — 200ms between calls
    await new Promise(r => setTimeout(r, 200))
  }

  const summary = {
    total: report.length,
    updated: report.filter(r => r.action === 'updated').length,
    skipped_no_doi: report.filter(r => r.action === 'skipped_no_doi').length,
    openalex_404: report.filter(r => r.action === 'openalex_404').length,
    openalex_other_error: report.filter(r => r.action?.startsWith('openalex_') && !['openalex_200', 'openalex_404', 'openalex_ok_no_institutions'].includes(r.action)).length,
    openalex_no_institutions: report.filter(r => r.action === 'openalex_ok_no_institutions').length,
    update_failed: report.filter(r => r.action === 'update_failed').length,
    by_source_updated: report
      .filter(r => r.action === 'updated')
      .reduce((acc: any, r) => { acc[r.source] = (acc[r.source] || 0) + 1; return acc }, {}),
    by_source_total: report
      .reduce((acc: any, r) => { acc[r.source] = (acc[r.source] || 0) + 1; return acc }, {})
  }

  return json({ ok: true, summary, report })
})

function extractDoi(url: string): string | null {
  if (!url) return null
  const m = url.match(/(10\.\d{4,9}\/[^\s]+)/i)
  return m ? m[1].replace(/[.,;)]+$/, '') : null
}

async function fetchOpenAlex(doi: string) {
  try {
    const r = await fetch(
      `https://api.openalex.org/works/doi:${encodeURIComponent(doi)}?select=authorships`,
      { headers: { 'User-Agent': 'GustoScience/1.0 (mailto:anders@crichton-fock.com)' } }
    )
    if (r.status === 404) return { ok: false, status: '404' }
    if (r.status === 429) return { ok: false, status: '429' }
    if (!r.ok) return { ok: false, status: String(r.status) }
    const data = await r.json()
    return { ok: true, status: '200', data }
  } catch (e: any) {
    return { ok: false, status: 'network_error', error: e.message }
  }
}

function json(body: any, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' }
  })
}
