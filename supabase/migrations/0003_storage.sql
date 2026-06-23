-- ============================================================================
-- GigCute — storage
-- A single public 'media' bucket holds avatars and company logos. Files live
-- under <kind>/<user-id>/<filename>, e.g. avatars/<uid>/... and logos/<uid>/...
--
-- Public read (so photo_url / logo_url resolve in the browser); authenticated
-- users can only write/replace/delete files in their own <uid> folder.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

-- Anyone can read media (URLs are public).
create policy "media: public read"
  on storage.objects for select
  using (bucket_id = 'media');

-- Authenticated users may upload only into a folder named after their own uid
-- (the second path segment: avatars/<uid>/file or logos/<uid>/file).
create policy "media: owner insert"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and (storage.foldername(name))[2] = auth.uid()::text);

create policy "media: owner update"
  on storage.objects for update to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[2] = auth.uid()::text);

create policy "media: owner delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[2] = auth.uid()::text);
