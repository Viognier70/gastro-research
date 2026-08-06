-- =============================================================================
-- HTML-entiteter i text-fälten — engångsstädning + funktion för framtida bruk
-- =============================================================================
-- APPLICERA MANUELLT I SQL-EDITORN — INTE via `supabase db push`.
--
-- BAKGRUND (mätt 2026-08-06):
--   167 titlar med &lt; eller &gt;
--   138 titlar med &amp;
--   av 34 722 relevanta artiklar (0,9 %)
--
--   Exempel: artikel f4295831 har title = "&lt;em&gt;Vitis vinifera&lt;/em&gt;
--   …" som renderas som LITERAL "<em>Vitis vinifera</em>" i overlayn OCH
--   i APA-referensen — citeringen blir obrukbar.
--
--   Källa: Crossref/Scopus/PubMed skickar ibland HTML-entiteter (`&amp;`,
--   `&lt;em&gt;` för italic-latinska binomen) i title-fältet. Vår parsning
--   strippade råa `<tag>` (rad 424-425 daily-fetch) men inte entiteter.
--   Frontendens _apaCleanTitle (rad 2601) strippar också bara tags, inte
--   entiteter — därför läckte hela vägen ut i citeringen.
--
-- LÖSNING I TRE STEG (denna migration är steg 1):
--   1. Engångscleanup — avkoda entiteter + strippa kvarvarande HTML-taggar
--      i title/abstract/journal/authors för samtliga träffar.
--   2. daily-fetch cleanText() vid saveArticle-topp (separat commit).
--   3. Frontend cleanTextField()-defensive decode (separat commit).
--
-- BESLUT — strippa HTML-taggar eller behåll dem?
--   Strippa. `<em>Vitis vinifera</em>` i en titel har inget värde i vår
--   rendering (vi renderar inte kursiv text i titlar, författare, tidskrift
--   eller abstract). Läsaren får `Vitis vinifera` som text — vetenskapligt
--   binom förlorar italics men blir läsbart, vilket är förbättring från
--   "<em>Vitis vinifera</em>" som literal ASCII.
--
-- DECODE-ORDNING — `&amp;` LAST:
--   Standard-defensiv ordning. Om en källa någon gång double-escapar
--   (`&amp;lt;` = literal `&lt;`), måste vi INTE avkoda `&amp;` först
--   (då blir det `&lt;` → `<`, fel). Vi ser inga double-escapes bland våra
--   305 rader idag, men ordningen är gratis försäkring mot framtida källor.
-- =============================================================================

-- ─── 1. Helper-funktion ────────────────────────────────────────────────────

create or replace function public.html_entity_decode_strip(t text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $function$
  select case when t is null then t else
    trim(
      regexp_replace(
        -- Named entities i defensiv ordning; &amp; sist.
        -- &#39; (dec numeric för apostrof) förekommer i pubmed-titlar.
        replace(replace(replace(replace(replace(replace(t,
          '&lt;',   '<'),
          '&gt;',   '>'),
          '&quot;', '"'),
          '&apos;', ''''),
          '&#39;',  ''''),
          '&amp;',  '&'),
        -- Strippa kvarvarande HTML-taggar helt (<em>, <sub>, <sup>, <i>).
        -- Efter decode:n står nu `<em>Vitis vinifera</em>` som riktig HTML;
        -- regex tar bort taggarna men behåller textinnehållet.
        '<[^>]+>', '', 'g'
      )
    )
  end;
$function$;

grant execute on function public.html_entity_decode_strip(text) to service_role;


-- ─── 2. Diagnostik-vy (kör före applicering för att se omfattning) ─────────
--
--   Verifiera counts före cleanup så vi kan jämföra före/efter:
--
--     select
--       count(*) filter (where title    ~ '&(lt|gt|amp|quot|apos|#39);') as title_hits,
--       count(*) filter (where abstract ~ '&(lt|gt|amp|quot|apos|#39);') as abstract_hits,
--       count(*) filter (where journal  ~ '&(lt|gt|amp|quot|apos|#39);') as journal_hits,
--       count(*) filter (where authors  ~ '&(lt|gt|amp|quot|apos|#39);') as authors_hits
--     from public.articles
--     where irrelevant is not true;
--
-- ─── 3. Engångscleanup ─────────────────────────────────────────────────────
--
-- Varje UPDATE är idempotent — WHERE-klausulen fångar bara rader som
-- fortfarande har entiteter, så re-applicering är no-op.

update public.articles
   set title = public.html_entity_decode_strip(title)
 where title ~ '&(lt|gt|amp|quot|apos|#39);'
    or title ~ '<[a-zA-Z][^>]*>';

update public.articles
   set abstract = public.html_entity_decode_strip(abstract)
 where abstract is not null
   and (abstract ~ '&(lt|gt|amp|quot|apos|#39);'
     or abstract ~ '<[a-zA-Z][^>]*>');

update public.articles
   set journal = public.html_entity_decode_strip(journal)
 where journal is not null
   and (journal ~ '&(lt|gt|amp|quot|apos|#39);'
     or journal ~ '<[a-zA-Z][^>]*>');

update public.articles
   set authors = public.html_entity_decode_strip(authors)
 where authors is not null
   and (authors ~ '&(lt|gt|amp|quot|apos|#39);'
     or authors ~ '<[a-zA-Z][^>]*>');


-- =============================================================================
-- Verifiering (efter apply):
--
--   -- 1. Alla counts ska vara 0:
--   select
--     count(*) filter (where title    ~ '&(lt|gt|amp|quot|apos|#39);') as title_hits,
--     count(*) filter (where abstract ~ '&(lt|gt|amp|quot|apos|#39);') as abstract_hits,
--     count(*) filter (where journal  ~ '&(lt|gt|amp|quot|apos|#39);') as journal_hits,
--     count(*) filter (where authors  ~ '&(lt|gt|amp|quot|apos|#39);') as authors_hits
--   from public.articles
--   where irrelevant is not true;
--
--   -- 2. Konkret exempel — f4295831 ska vara ren:
--   select id, title from public.articles where id::text like 'f4295831%';
--   -- expect: title utan &lt;em&gt;/&lt;/em&gt;, ren text
--
--   -- 3. Funktionen sanity — testa i isolation:
--   select public.html_entity_decode_strip('&lt;em&gt;Vitis vinifera&lt;/em&gt; &amp; more');
--   -- expect: 'Vitis vinifera & more'
-- =============================================================================
