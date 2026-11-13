-- =====================================================================
-- Espaces Partagés : compléments (à exécuter une fois, après schema.sql)
-- =====================================================================

-- L'e-mail de chaque compte, visible uniquement par la personne et l'équipe
alter table public.profiles add column if not exists email text default '';
update public.profiles p set email = u.email from auth.users u where u.id = p.id;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, role, profil, newsletter, email)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'name', 'Sans nom'),
          coalesce(new.raw_user_meta_data->>'role', 'porteur'),
          coalesce(new.raw_user_meta_data->>'profil', ''),
          coalesce((new.raw_user_meta_data->>'newsletter')::boolean, false),
          coalesce(new.email, ''));
  return new;
end $$;

-- Un compte ne peut pas modifier lui-même son e-mail affiché à l'équipe, ses droits ou sa suspension
create or replace function public.protect_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    new.is_admin := old.is_admin; new.suspendu := old.suspendu; new.motif := old.motif;
    new.role := old.role; new.email := old.email;
  end if;
  return new;
end $$;

-- Délai de réponse moyen d'un lieu (en heures), sans révéler les conversations
create or replace function public.delai_reponse(uid uuid) returns double precision
language sql stable security definer set search_path = public as $$
  select avg(extract(epoch from (r.first_reply - t.created_at)) / 3600)
  from public.threads t
  cross join lateral (select min(m.created_at) as first_reply from public.messages m
                      where m.thread_id = t.id and m.from_id = uid and not m.sys) r
  where t.to_id = uid and t.request is not null and r.first_reply is not null;
$$;
grant execute on function public.delai_reponse(uuid) to anon, authenticated;
