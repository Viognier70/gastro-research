> _Arkiv — skriven under namnet Gustema, nu Gusto Science._

# Gustema — Feedback: användbarhet + felflaggning
**Spec 2026-07-23 · bygg före lansering**

## Varför

Två problem som denna funktion löser:

1. **Anders är ensam om att upptäcka fel** i ~9 700 TRIAD-analyser. Stickprovs-
   granskningen (2026-07-23) fann systematisk fabricering — men den skalar inte.
   Behövs en kanal där andra kan flagga.
2. **Vi vet inte vad som är värdefullt.** Ingen data på vilka analyser/svar som
   faktiskt hjälper praktiker. Utan den signalen är all prioritering gissning.

**Nyckelinsikt: korrekthet och användbarhet är OLIKA axlar och måste mätas
separat.** En analys kan vara korrekt men värdelös, eller — farligast — *användbar
men fel* (konkret och övertygande just för att detaljerna är påhittade; jfr
"150°C i fem minuter" som kändes hjälpsamt).

---

## Vad som byggs

### UI — två element, båda minimala

**Under varje TRIAD-analys** (i artikelmodalen, alla fem roller):
```
Hjälpte den här analysen dig?  👍  👎     ·     ⚑ Rapportera fel
```

**Under varje Ask-svar** (syntesvyn):
```
Besvarade detta din fråga?  👍  👎     ·     ⚑ Rapportera fel
```

**Flaggan öppnar tre fasta val** (inget fritextfält i v1):
- Stämmer inte med artikeln
- Uppfinner detaljer som inte finns i källan
- Fel för min yrkesroll

Ingen fritext = ingen moderering, ingen juridisk exponering, inget tomhets-
problem. Två sekunder att klicka.

### Datamodell

```sql
create table public.content_feedback (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  source       text not null check (source in ('triad','ask')),
  article_id   uuid references public.articles(id) on delete cascade,  -- null för ask
  ask_query    text,                        -- frågan, för source='ask'
  role         text not null,               -- dbRole analysen gällde
  vote         smallint check (vote in (-1, 1)),          -- 👎 / 👍, null om bara flagga
  flag_type    text check (flag_type in
                 ('not_in_article','invented_detail','wrong_role')),  -- null om bara vote
  is_pro       boolean not null default false,   -- snapshot vid tillfället, för viktning
  created_at   timestamptz not null default now(),
  unique (user_id, source, article_id, role)   -- en röst per user/analys/roll
);
```

Notering: `is_pro` sparas som ögonblicksbild så aggregatet kan viktas även om
användaren senare byter plan.

**RLS:** inloggade kan skriva egna rader, läsa aggregat via vy. Ingen kan läsa
andras enskilda rader.

### Åtkomst
**Öppet för alla inloggade** (ej bara Pro). Skäl: mer data, och Free-användare
som röstar blir engagerade — en väg mot konvertering. Men **visa Pro-andel i
aggregatet** ("8 av 10 Pro-medlemmar fann detta användbart") så signalen kan
viktas.

---

## Vad signalerna används till

| Mönster | Betyder | Åtgärd |
|---------|---------|--------|
| Hög 👍, inga flaggor | Fungerar väl | Lyft fram — "mest värdefulla för din roll" |
| **Hög 👍 + flaggor** | **Övertygande men fel** | **Prioritera granskning — farligast** |
| Låg 👍, inga flaggor | Korrekt men trist | Kvalitetsfråga, ej fara |
| Många 👎 på en roll/ämne | Systematisk svaghet | Justera prompt eller relevanströskel |
| Ask: 👍 på praktikerfrågor, 👎 på forskarfrågor | Syntesen tjänar en publik bättre | Rolldifferentierad prompt |

Rad två är hela poängen med att mäta båda axlarna: den fångar analyser ingen
skulle ifrågasätta av sig själv, men som en uppmärksam läsare flaggar.

---

## Granskningsvy (för Anders)

Enkel intern vy — kan vara SQL-query i första versionen, senare en sida:

```sql
-- Flaggade analyser, prioriterade efter användning
select a.title, f.role, f.flag_type,
       count(*) filter (where f.flag_type is not null) as flaggor,
       count(*) filter (where f.vote = 1) as tummar_upp,
       count(*) filter (where f.is_pro and f.flag_type is not null) as pro_flaggor
  from content_feedback f
  join articles a on a.id = f.article_id
 where f.source = 'triad'
 group by a.title, f.role, f.flag_type
having count(*) filter (where f.flag_type is not null) > 0
 order by tummar_upp desc, flaggor desc;   -- populära OCH flaggade först
```

---

## Vad som INTE byggs i v1 (medvetet)

- **Fritextkommentarer** — kräver moderering, juridisk exponering, och tom
  kommentarsfunktion signalerar "ingen bryr sig". Kommer i steg 3 när community
  finns (se `gustema-kvalitetssakring-spec.md` Del C).
- **Publik visning av flaggor** — i v1 ser bara Anders dem. Att visa
  "⚑ ifrågasatt" för alla kräver en tröskel och en granskningsprocess som inte
  finns än.
- **Praktikerkunskap som fjärde lager** — det större bygget, senare.

---

## Byggordning

1. Migration: `content_feedback` + RLS + aggregat-vy
2. UI i artikelmodalen (TRIAD) — 👍/👎 + flagga med tre val
3. UI i Ask-svarsvyn — samma element
4. Granskningsquery åt Anders
5. Verifiera: rösta som Free-user och Pro-user, bekräfta att rader skrivs rätt,
   att unique-constraint hindrar dubbelröstning, och att RLS blockerar läsning
   av andras rader

**Storlek:** ~1 dag. Inget LLM-anrop, ingen kostnad, ingen moderering.

---

## Koppling till kvalitetsarbetet

Detta är den **skalbara** delen av kvalitetssäkringen. Stickprovsmätningen
(Del A i `gustema-kvalitetssakring-spec.md`) ger en baslinje vid ett tillfälle;
feedback-funktionen ger löpande signal från riktiga användare i riktiga
situationer — inklusive fall Anders aldrig skulle tänka på att testa.

Efter batch-regenereringen bör en ny stickprovsmätning göras. Feedback-datan
blir sedan det som håller kvaliteten uppe *mellan* mätningarna.
