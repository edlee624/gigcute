-- ============================================================================
-- GigCute — jobs_search: relevance-ranked job search
-- Ranks active jobs by full-text relevance against a query string (uses the
-- FTS expression index from 0024). Powers "Recommended for you" — the caller
-- passes the seeker's profile keywords joined with " or " for OR matching.
-- Public (anon + authenticated); reads active jobs only.
-- ============================================================================
create or replace function public.jobs_search(
  p_q      text default null,
  p_remote boolean default null,
  p_limit  int default 12,
  p_offset int default 0
)
returns setof public.jobs
language sql stable security definer set search_path = public as $$
  select j.*
  from public.jobs j
  where j.is_active
    and (p_remote is not true or j.remote)
    and (
      p_q is null or btrim(p_q) = ''
      or to_tsvector('english',
           coalesce(j.title,'') || ' ' || coalesce(j.company,'') || ' ' ||
           coalesce(j.location,'') || ' ' || coalesce(j.description,''))
         @@ websearch_to_tsquery('english', p_q)
    )
  order by
    (case when p_q is null or btrim(p_q) = '' then 0
          else ts_rank(
            to_tsvector('english',
              coalesce(j.title,'') || ' ' || coalesce(j.company,'') || ' ' || coalesce(j.description,'')),
            websearch_to_tsquery('english', p_q))
     end) desc,
    j.posted_at desc nulls last
  limit  greatest(1, least(coalesce(p_limit, 12), 50))
  offset greatest(0, coalesce(p_offset, 0));
$$;

grant execute on function public.jobs_search(text, boolean, int, int) to anon, authenticated;
