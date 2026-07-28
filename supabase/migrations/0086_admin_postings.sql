-- ============================================================================
-- GigCute — admin visibility into jobs posted DIRECTLY by recruiters.
--
-- The admin panel already covers seekers, feedback, event activity, and the
-- ingested jobs feed, but had no window into the `postings` table — the roles
-- recruiters create on GigCute itself — or their engagement. This adds one
-- is_admin()-gated RPC returning a summary plus a per-posting row with the
-- company, the recruiter who posted it, and activity counts (views, seeker
-- interest, recruiter outreach). Read-only; mirrors admin_users' shape.
-- ============================================================================

create or replace function public.admin_postings(p_search text default null, p_limit int default 200)
returns jsonb
language plpgsql stable security definer set search_path = public, auth as $$
declare result jsonb; q text;
begin
  if not public.is_admin() then return null; end if;
  q := nullif(trim(coalesce(p_search, '')), '');

  select jsonb_build_object(
    'total',        (select count(*) from public.postings),
    'active',       (select count(*) from public.postings where status = 'active'),
    'draft',        (select count(*) from public.postings where status = 'draft'),
    'total_views',  (select coalesce(sum(views), 0) from public.postings),
    'total_interest', (select count(*) from public.seeker_interest),
    'companies',    (select count(distinct company_id) from public.postings),
    'by_status', coalesce((
      select jsonb_object_agg(s, c) from (
        select status::text s, count(*) c from public.postings group by status
      ) x
    ), '{}'::jsonb),
    'postings', coalesce((
      select jsonb_agg(row order by (row->>'created_at') desc) from (
        select jsonb_build_object(
          'id',            pg.id,
          'title',         pg.title,
          'status',        pg.status,
          'tier',          pg.tier,
          'department',    pg.department,
          'seniority',     pg.seniority,
          'location',      nullif(trim(coalesce(pg.city,'') || case when pg.location_type is not null then ' ('||pg.location_type||')' else '' end), ''),
          'employment',    pg.employment_type,
          'salary_min',    pg.salary_min,
          'salary_max',    pg.salary_max,
          'company',       co.name,
          'company_id',    pg.company_id,
          'verified',      co.verified,
          'recruiter',     rp.full_name,
          'recruiter_email', ru.email,
          'created_at',    pg.created_at,
          'published_at',  pg.published_at,
          'expires_at',    pg.expires_at,
          'views',         coalesce(pg.views, 0),
          'unique_viewers',(select count(distinct coalesce(pv.viewer_key, pv.viewer_id::text)) from public.posting_views pv where pv.posting_id = pg.id),
          'interest',      (select count(*) from public.seeker_interest si where si.posting_id = pg.id),
          'outreach',      (select count(*) from public.recruiter_interest ri where ri.posting_id = pg.id)
        ) as row
        from public.postings pg
        left join public.companies co on co.id = pg.company_id
        left join public.profiles  rp on rp.id = pg.created_by
        left join auth.users       ru on ru.id = pg.created_by
        where q is null
           or pg.title  ilike '%'||q||'%'
           or co.name   ilike '%'||q||'%'
           or rp.full_name ilike '%'||q||'%'
           or ru.email  ilike '%'||q||'%'
        limit greatest(1, least(coalesce(p_limit, 200), 500))
      ) sub
    ), '[]'::jsonb)
  ) into result;

  return result;
end $$;

grant execute on function public.admin_postings(text, int) to authenticated;
