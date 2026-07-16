-- ============================================================================
-- GigCute — server-side job matching for seekers.
--
-- Why: the old path ORed common words across title+company+location+description
-- ("developer or support or technology"), so any job whose DESCRIPTION said
-- "support" became a candidate — Social Worker and Veterinary Technician were
-- being pitched to a front-end developer. Scoring can't rescue a bad candidate
-- set, and scoring a 50-row window in the browser can't see the other 166k rows.
--
-- Now: retrieve TITLE-FIRST with English stemming (so "developer" matches
-- "Software Development"), then rank in SQL over the whole feed.
--   title fit  0..60  dominant — it must be the right ROLE (trigram word_similarity,
--                     60 for outright phrase containment)
--   skills     0..25  saturating (~3 strong hits = full marks)
--   salary   -12..10  clears their floor / well under it
--   freshness  0..5
-- ============================================================================

-- Normalise a title for comparison: drop seniority words and punctuation so
-- "Senior Front-End Developer" and "front end developer" agree.
create or replace function public.core_title(t text)
returns text language sql immutable as $$
  select btrim(regexp_replace(
           regexp_replace(
             regexp_replace(lower(coalesce(t,'')), '[^a-z0-9+#/ ]', ' ', 'g'),
             '\m(senior|junior|sr|jr|staff|principal|lead|entry|associate|intern|trainee|graduate|iii|ii|iv|i)\M', ' ', 'g'),
           '\s+', ' ', 'g'));
$$;

-- Title-only FTS index (expression must match the query below exactly to be used).
create index if not exists jobs_title_fts_idx
  on public.jobs using gin (to_tsvector('english', coalesce(title, '')));
-- Trigram index on title for the fuzzy word_similarity scoring.
-- NOTE: pg_trgm is installed in `public` on this project (not `extensions`).
create index if not exists jobs_title_trgm_idx
  on public.jobs using gin (title public.gin_trgm_ops);

create or replace function public.match_jobs_for_seeker(
  p_titles  text[],
  p_skills  text[] default '{}',
  p_sal_min int default null,
  p_remote  boolean default null,
  p_limit   int default 20
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare qtext text; q tsquery; result jsonb;
begin
  -- OR across the seeker's target titles; AND the core words within each one, so
  -- "front end developer" needs front+end+develop in the TITLE (not the body).
  -- tsquery's OR operator is '|' (a single pipe) — '||' is a syntax error here.
  select string_agg('(' || plainto_tsquery('english', public.core_title(t))::text || ')', ' | ')
    into qtext
  from unnest(coalesce(p_titles, '{}')) t
  where btrim(public.core_title(t)) <> ''
    and plainto_tsquery('english', public.core_title(t))::text <> '';

  if qtext is null or btrim(qtext) = '' then return '[]'::jsonb; end if;
  q := qtext::tsquery;

  return coalesce((
    with cand as (
      -- 1) Title-matched candidates only, best-ranked first.
      select j.id, j.title, j.company, j.location, j.remote, j.salary_min, j.salary_max,
             j.salary_currency, j.url, j.description, j.tags, j.posted_at, j.source, j.external_id
      from public.jobs j
      where j.is_active
        and to_tsvector('english', coalesce(j.title, '')) @@ q
        and (p_remote is not true or j.remote)
      order by ts_rank(to_tsvector('english', coalesce(j.title, '')), q) desc,
               j.posted_at desc nulls last
      limit 150
    ),
    fit as (
      -- 2) Title fit is cheap (title-only): outright phrase containment wins, else
      --    how much of the target appears in the title (trigram word_similarity).
      select c.*, (
        select max(case
            when position(public.core_title(tt) in public.core_title(c.title)) > 0 then 60
            else round(60 * word_similarity(public.core_title(tt), public.core_title(c.title)))::int
          end)
        from unnest(p_titles) tt
        where btrim(public.core_title(tt)) <> ''
      ) as tfit
      from cand c
    ),
    top as (
      -- 3) Only the best titles earn the expensive part. Skill scoring ILIKEs every
      --    skill against the full description, so it runs on ~50 rows, not 150.
      select * from fit order by tfit desc nulls last limit 50
    ),
    scored as (
      select t.*,
        least(25,
          (select count(*) from unnest(coalesce(p_skills, '{}')) sk
             where btrim(sk) <> '' and t.title ilike '%' || sk || '%') * 9
          +
          (select count(*) from unnest(coalesce(p_skills, '{}')) sk
             where btrim(sk) <> '' and coalesce(t.description, '') ilike '%' || sk || '%') * 4
        ) as skill_score,
        case when p_sal_min is null then 0
             when coalesce(t.salary_max, t.salary_min) is null then 0
             when coalesce(t.salary_max, t.salary_min) >= p_sal_min then 10
             when coalesce(t.salary_max, t.salary_min) < p_sal_min * 0.85 then -12
             else 3 end as sal_score,
        case when t.posted_at is null then 0
             when t.posted_at > now() - interval '7 days' then 3
             when t.posted_at > now() - interval '30 days' then 1
             else 0 end as fresh
      from top t
    )
    select jsonb_agg(to_jsonb(r) order by r.score desc)
    from (
      select s.id, s.title, s.company, s.location, s.remote,
             s.salary_min, s.salary_max, s.salary_currency,
             s.url, s.description, s.tags, s.posted_at, s.source, s.external_id,
             greatest(1, least(99, s.tfit + s.skill_score + s.sal_score + s.fresh)) as score
      from scored s
      order by score desc
      limit greatest(1, least(coalesce(p_limit, 20), 50))
    ) r
  ), '[]'::jsonb);
end $$;

grant execute on function public.match_jobs_for_seeker(text[], text[], int, boolean, int) to anon, authenticated;
