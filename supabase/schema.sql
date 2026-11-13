-- =====================================================================
-- Espaces Partagés (Underwave) : structure de la base de données
-- À coller dans Supabase > SQL Editor, puis « Run ».
-- =====================================================================

-- ---------- Profils (un par compte) ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null,
  role text not null check (role in ('lieu','porteur')),
  profil text default '',
  bio text default '',
  liens text default '',
  newsletter boolean not null default false,
  is_admin boolean not null default false,
  suspendu boolean not null default false,
  motif text default '',
  created_at timestamptz not null default now()
);

-- Qui est dans l'équipe Underwave ?
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;
create or replace function public.is_active(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select not suspendu from public.profiles where id = uid), false);
$$;

-- Création automatique du profil à l'inscription
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, role, profil, newsletter)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'name', 'Sans nom'),
          coalesce(new.raw_user_meta_data->>'role', 'porteur'),
          coalesce(new.raw_user_meta_data->>'profil', ''),
          coalesce((new.raw_user_meta_data->>'newsletter')::boolean, false));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Un compte ne peut pas se donner lui-même les droits d'équipe ni se « dé-suspendre »
create or replace function public.protect_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- auth.uid() est vide dans l'éditeur SQL de Supabase : l'équipe technique garde la main
  if auth.uid() is not null and not public.is_admin() then
    new.is_admin := old.is_admin; new.suspendu := old.suspendu; new.motif := old.motif; new.role := old.role;
  end if;
  return new;
end $$;
create trigger protect_profile before update on public.profiles
  for each row execute function public.protect_profile();

alter table public.profiles enable row level security;
create policy "profil : lecture de soi ou équipe" on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy "profil : modification de soi ou équipe" on public.profiles for update using (id = auth.uid() or public.is_admin());
create policy "profil : suppression de soi ou équipe" on public.profiles for delete using (id = auth.uid() or public.is_admin());

-- Ce que tout le monde peut voir d'un compte (jamais l'e-mail)
create view public.profiles_public as
  select id, name, role, profil, bio, liens from public.profiles where not suspendu;
grant select on public.profiles_public to anon, authenticated;

-- ---------- Lieux ----------
create table public.lieux (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'en_attente' check (status in ('en_attente','publie','refuse','retire')),
  motif text default '',
  nom text not null,
  type text not null,
  arr text not null,
  adresse_masquee boolean not null default false,
  transports text default '',
  description text not null,
  capacite int,
  espace text default '',
  equip text[] default '{}',
  evts text[] default '{}',
  frequence text default '',
  conditions text[] default '{}',
  dispo text default '',
  site text default '',
  insta text default '',
  contact_public text default '',
  photos text[] default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- L'adresse est à part : elle n'est visible par tout le monde que si le lieu ne l'a pas masquée
create table public.lieux_adresses (
  lieu_id uuid primary key references public.lieux(id) on delete cascade,
  adresse text default '',
  lat double precision,
  lng double precision
);
-- Note interne de l'équipe, jamais visible par le lieu
create table public.lieux_notes (
  lieu_id uuid primary key references public.lieux(id) on delete cascade,
  note text default ''
);

-- Seule l'équipe change le statut et le motif ; toute nouvelle fiche part en validation
create or replace function public.protect_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then
      new.status := 'en_attente'; new.motif := '';
    else
      new.status := old.status; new.motif := old.motif;
    end if;
  end if;
  if tg_op = 'UPDATE' then new.updated_at := now(); end if;
  return new;
end $$;
create trigger protect_lieu before insert or update on public.lieux
  for each row execute function public.protect_status();

alter table public.lieux enable row level security;
create policy "lieux : lecture" on public.lieux for select using (
  (status = 'publie' and public.is_active(owner)) or owner = auth.uid() or public.is_admin());
create policy "lieux : création" on public.lieux for insert with check (owner = auth.uid() and public.is_active(auth.uid()));
create policy "lieux : modification" on public.lieux for update using (owner = auth.uid() or public.is_admin());
create policy "lieux : suppression" on public.lieux for delete using (owner = auth.uid() or public.is_admin());

alter table public.lieux_notes enable row level security;
create policy "notes : équipe" on public.lieux_notes for all using (public.is_admin()) with check (public.is_admin());

-- ---------- Annonces ----------
create table public.annonces (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('recherche','creneau')),
  status text not null default 'en_attente' check (status in ('en_attente','ouverte','refusee','retiree','trouve','close')),
  motif text default '',
  titre text not null,
  evt text default '',
  evts_acceptes text[] default '{}',
  periode text default '',
  personnes int,
  secteur text default '',
  besoins text default '',
  conditions text[] default '{}',
  lieu uuid references public.lieux(id) on delete cascade,
  created_at timestamptz not null default now()
);
-- L'auteur·ice peut seulement clore son annonce ou la marquer « lieu trouvé »
create or replace function public.protect_annonce() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then new.status := 'en_attente'; new.motif := '';
    elsif new.status not in ('trouve','close') then new.status := old.status; new.motif := old.motif;
    end if;
  end if;
  return new;
end $$;
create trigger protect_annonce before insert or update on public.annonces
  for each row execute function public.protect_annonce();

alter table public.annonces enable row level security;
create policy "annonces : lecture" on public.annonces for select using (
  (status = 'ouverte' and public.is_active(owner) and created_at > now() - interval '90 days')
  or owner = auth.uid() or public.is_admin());
create policy "annonces : création" on public.annonces for insert with check (owner = auth.uid() and public.is_active(auth.uid()));
create policy "annonces : modification" on public.annonces for update using (owner = auth.uid() or public.is_admin());
create policy "annonces : suppression" on public.annonces for delete using (owner = auth.uid() or public.is_admin());

-- ---------- Conversations et messages (privés) ----------
create table public.threads (
  id uuid primary key default gen_random_uuid(),
  from_id uuid not null references public.profiles(id) on delete cascade,
  to_id uuid not null references public.profiles(id) on delete cascade,
  lieu uuid references public.lieux(id) on delete set null,
  annonce uuid references public.annonces(id) on delete set null,
  request jsonb,
  status text not null default 'envoyee' check (status in ('envoyee','vue','acceptee','refusee')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Seul·e la personne qui reçoit la demande peut l'accepter ou la décliner
create or replace function public.protect_thread() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and auth.uid() is not null and auth.uid() <> old.to_id then new.status := old.status; end if;
  return new;
end $$;
create trigger protect_thread before update on public.threads
  for each row execute function public.protect_thread();

alter table public.threads enable row level security;
-- L'équipe Underwave n'a PAS accès aux conversations.
create policy "threads : membres" on public.threads for select using (auth.uid() in (from_id, to_id));
create policy "threads : création" on public.threads for insert with check (from_id = auth.uid() and public.is_active(auth.uid()));
create policy "threads : mise à jour" on public.threads for update using (auth.uid() in (from_id, to_id));

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.threads(id) on delete cascade,
  from_id uuid references public.profiles(id) on delete cascade,
  text text not null,
  sys boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.messages enable row level security;
create policy "messages : lecture membres" on public.messages for select using (
  exists (select 1 from public.threads t where t.id = thread_id and auth.uid() in (t.from_id, t.to_id)));
create policy "messages : écriture membres" on public.messages for insert with check (
  from_id = auth.uid() and public.is_active(auth.uid())
  and exists (select 1 from public.threads t where t.id = thread_id and auth.uid() in (t.from_id, t.to_id)));

create table public.thread_reads (
  thread_id uuid references public.threads(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (thread_id, user_id)
);
alter table public.thread_reads enable row level security;
create policy "lu : soi" on public.thread_reads for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Politiques de l'adresse (après la création des conversations)
alter table public.lieux_adresses enable row level security;
create or replace function public.can_see_address(lid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.lieux l where l.id = lid and (
    l.owner = auth.uid() or public.is_admin()
    or (l.status = 'publie' and not l.adresse_masquee)
    or exists (select 1 from public.threads t where t.lieu = l.id and t.status = 'acceptee' and auth.uid() in (t.from_id, t.to_id))));
$$;
create policy "adresse : lecture" on public.lieux_adresses for select using (public.can_see_address(lieu_id));
create policy "adresse : écriture" on public.lieux_adresses for all using (
  exists (select 1 from public.lieux l where l.id = lieu_id and (l.owner = auth.uid() or public.is_admin())))
  with check (exists (select 1 from public.lieux l where l.id = lieu_id and (l.owner = auth.uid() or public.is_admin())));

-- ---------- Signalements (visibles par l'équipe seulement) ----------
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  target text not null check (target in ('lieu','annonce','compte')),
  target_id uuid not null,
  by uuid references public.profiles(id) on delete set null,
  text text not null,
  conv jsonb,
  status text not null default 'ouvert' check (status in ('ouvert','traite')),
  created_at timestamptz not null default now()
);
alter table public.reports enable row level security;
create policy "signalement : envoi" on public.reports for insert with check (by = auth.uid());
create policy "signalement : équipe" on public.reports for select using (public.is_admin());
create policy "signalement : traitement" on public.reports for update using (public.is_admin());
create policy "signalement : suppression" on public.reports for delete using (public.is_admin());

-- ---------- Né ici ----------
create table public.neici (
  id uuid primary key default gen_random_uuid(),
  lieu uuid references public.lieux(id) on delete cascade,
  by uuid references public.profiles(id) on delete cascade,
  titre text not null,
  date text default '',
  texte text not null,
  photo text default '',
  alt boolean not null default false,
  status text not null default 'en_attente' check (status in ('en_attente','publie','refuse')),
  created_at timestamptz not null default now()
);
create or replace function public.protect_neici() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if tg_op = 'INSERT' then new.status := 'en_attente'; new.alt := false;
    else new.status := old.status; new.alt := old.alt; end if;
  end if;
  return new;
end $$;
create trigger protect_neici before insert or update on public.neici
  for each row execute function public.protect_neici();
alter table public.neici enable row level security;
create policy "neici : lecture" on public.neici for select using (status = 'publie' or by = auth.uid() or public.is_admin());
create policy "neici : création" on public.neici for insert with check (by = auth.uid() and public.is_active(auth.uid()));
create policy "neici : modération" on public.neici for update using (public.is_admin());
create policy "neici : suppression" on public.neici for delete using (by = auth.uid() or public.is_admin());

-- ---------- Demandes ALT ----------
create table public.alt_demandes (
  id uuid primary key default gen_random_uuid(),
  by uuid references public.profiles(id) on delete set null,
  projet text not null,
  lieu uuid references public.lieux(id) on delete set null,
  date text default '',
  format text default '',
  description text not null,
  liens text default '',
  formats text[] default '{}',
  email text default '',
  status text not null default 'nouvelle' check (status in ('nouvelle','encours','relaye','nonretenu')),
  created_at timestamptz not null default now()
);
alter table public.alt_demandes enable row level security;
create policy "alt : envoi" on public.alt_demandes for insert with check (true);
create policy "alt : équipe" on public.alt_demandes for select using (public.is_admin());
create policy "alt : traitement" on public.alt_demandes for update using (public.is_admin());

-- ---------- Journal des e-mails automatiques (équipe) ----------
create table public.emails (
  id uuid primary key default gen_random_uuid(),
  to_user uuid references public.profiles(id) on delete set null,
  to_email text not null,
  sujet text not null,
  texte text not null,
  envoye boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.emails enable row level security;
create policy "emails : équipe" on public.emails for all using (public.is_admin()) with check (public.is_admin());

-- ---------- Photos ----------
insert into storage.buckets (id, name, public) values ('photos', 'photos', true) on conflict do nothing;
create policy "photos : lecture publique" on storage.objects for select using (bucket_id = 'photos');
create policy "photos : envoi par son dossier" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos : suppression par son dossier" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------- Suppression de son propre compte (droit à l'effacement) ----------
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'non connecté'; end if;
  delete from auth.users where id = auth.uid();  -- supprime en cascade profil, lieux, annonces, messages…
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---------- Droits d'accès aux tables (obligatoire sur les nouveaux projets) ----------
grant usage on schema public to anon, authenticated;
grant select on public.lieux, public.annonces, public.neici, public.lieux_adresses to anon;
grant insert on public.alt_demandes to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on function public.is_admin(), public.is_active(uuid), public.can_see_address(uuid) to anon, authenticated;

-- ---------- Après ta propre inscription sur le site ----------
-- Remplace l'e-mail ci-dessous par le tien, puis exécute cette ligne seule
-- pour te donner l'accès « Gestion » :
-- update public.profiles set is_admin = true where id = (select id from auth.users where email = 'underwave.asso@gmail.com');
