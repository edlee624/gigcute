-- ============================================================================
-- GigCute — make jobs_search fast (drop ts_rank ordering)
-- The original ranked matches with ts_rank in the ORDER BY, which forces
-- Postgres to compute a rank for EVERY matched row and sort them all. For a
-- common term ("designer", "product") that's thousands of rows → the query
-- exceeded the anon statement timeout (~8s) and returned nothing, so "Best
-- match" silently fell back to an empty/newest board.
--
-- The client now re-ranks the returned candidates by a richer relevance score
-- (title + skills + recency + remote fit), so the RPC only needs to return a
-- fast candidate set. Filter via the GIN FTS index (@@) and order by recency —
-- no per-row ranking. Same signature, so no client/API change required.
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
  order by j.posted_at desc nulls last
  limit  greatest(1, least(coalesce(p_limit, 12), 50))
  offset greatest(0, coalesce(p_offset, 0));
$$;

grant execute on function public.jobs_search(text, boolean, int, int) to anon, authenticated;
