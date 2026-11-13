-- =====================================================================
-- Espaces Partagés : alertes e-mail (envoyées par Brevo)
-- À exécuter une fois, après schema.sql et 02-complements.sql.
-- Prérequis : la clé API Brevo enregistrée dans le coffre de Supabase
-- sous le nom « brevo_api_key » (voir les instructions).
-- =====================================================================

create extension if not exists pg_net with schema extensions;

-- Réglages : adresse qui reçoit les alertes de l'équipe
create table if not exists public.reglages (cle text primary key, valeur text not null);
alter table public.reglages enable row level security;
insert into public.reglages (cle, valeur) values ('email_equipe', 'underwave.asso@gmail.com')
  on conflict (cle) do nothing;

-- Mise en page des e-mails (mêmes couleurs que les e-mails d'inscription)
create or replace function public.email_html(texte text, bouton text default null, lien text default null)
returns text language sql immutable set search_path = public as $$
  select '<div style="margin:0;padding:24px 16px;background:#ffffff;font-family:Arial,Helvetica,sans-serif;color:#000000;">'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px;margin:0 auto;">'
    || '<tr><td style="padding:0 0 20px;"><img src="https://underwave.fr/assets/logo/logo-email.png" width="39" height="24" alt="Underwave" style="display:block;border:0;"></td></tr>'
    || '<tr><td style="padding:0 0 20px;font-size:16px;line-height:1.5;">'
    || replace(replace(replace(replace(texte, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), E'\n', '<br>')
    || '</td></tr>'
    || case when bouton is not null then
         '<tr><td style="padding:0 0 20px;"><a href="' || lien || '" style="display:inline-block;padding:12px 22px;background:#DEFE52;color:#000000;font-size:16px;font-weight:bold;text-decoration:none;border-radius:99px;">' || bouton || '</a></td></tr>'
       else '' end
    || '<tr><td style="padding:12px 0 0;border-top:1px solid #000000;font-size:13px;line-height:1.5;color:#555555;">Espaces Partagés, un projet de l’association Underwave<br><a href="https://espaces-partages.underwave.fr" style="color:#000000;">espaces-partages.underwave.fr</a></td></tr>'
    || '</table></div>';
$$;

-- Envoi d'un e-mail par l'API de Brevo
create or replace function public.envoyer_email(dest text, sujet text, texte text, bouton text default null, lien text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare cle text;
begin
  if dest is null or dest = '' then return; end if;
  select decrypted_secret into cle from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  if cle is null then return; end if;
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', cle, 'content-type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', 'Underwave', 'email', 'contact@underwave.fr'),
      'to', jsonb_build_array(jsonb_build_object('email', dest)),
      'subject', sujet,
      'textContent', texte || coalesce(E'\n\n' || bouton || ' : ' || lien, ''),
      'htmlContent', public.email_html(texte, bouton, lien)
    )
  );
end $$;
revoke execute on function public.envoyer_email(text, text, text, text, text) from public, anon, authenticated;

-- 1. E-mails de l'équipe (lieu publié, refusé, retiré, compte suspendu…) : envoyés dès leur enregistrement
create or replace function public.alerte_email_equipe() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.envoyer_email(new.to_email, new.sujet, new.texte, 'Ouvrir Espaces Partagés', 'https://espaces-partages.underwave.fr/#compte');
  update public.emails set envoye = true where id = new.id;
  return null;
end $$;
drop trigger if exists emails_envoi on public.emails;
create trigger emails_envoi after insert on public.emails for each row execute function public.alerte_email_equipe();

-- 2. Nouveau message : une alerte par conversation, puis plus rien tant que la personne n'a pas lu
create table if not exists public.alertes_messages (
  thread_id uuid references public.threads(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  sent_at timestamptz not null default now(),
  primary key (thread_id, user_id)
);
alter table public.alertes_messages enable row level security;

create or replace function public.alerte_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare t public.threads; dest uuid; e text; nom text; lieu_nom text; deja timestamptz; lu timestamptz;
begin
  select * into t from public.threads where id = new.thread_id;
  if t.id is null then return null; end if;
  dest := case when new.from_id = t.from_id then t.to_id else t.from_id end;
  if dest is null or dest = new.from_id then return null; end if;
  select email into e from public.profiles where id = dest and not suspendu;
  if e is null or e = '' then return null; end if;
  select sent_at into deja from public.alertes_messages where thread_id = t.id and user_id = dest;
  select read_at into lu from public.thread_reads where thread_id = t.id and user_id = dest;
  if deja is not null and (lu is null or lu < deja) then return null; end if;
  select name into nom from public.profiles where id = new.from_id;
  select l.nom into lieu_nom from public.lieux l where l.id = t.lieu;
  insert into public.alertes_messages (thread_id, user_id, sent_at) values (t.id, dest, now())
    on conflict (thread_id, user_id) do update set sent_at = now();
  perform public.envoyer_email(e,
    'Nouveau message de ' || coalesce(nom, 'un membre') || ' sur Espaces Partagés',
    'Bonjour,' || E'\n\n' || coalesce(nom, 'Un membre') || ' vous a écrit sur Espaces Partagés'
      || coalesce(' à propos de « ' || lieu_nom || ' »', '') || '.'
      || E'\n\n' || 'Connectez-vous pour lire le message et répondre.',
    'Lire le message', 'https://espaces-partages.underwave.fr/#messages');
  return null;
end $$;
drop trigger if exists messages_alerte on public.messages;
create trigger messages_alerte after insert on public.messages for each row execute function public.alerte_message();

-- 3. Alertes pour l'équipe : contenus à valider, signalements, demandes ALT
create or replace function public.alerte_equipe(sujet text, texte text) returns void
language plpgsql security definer set search_path = public as $$
declare e text;
begin
  select valeur into e from public.reglages where cle = 'email_equipe';
  perform public.envoyer_email(e, sujet, texte, 'Ouvrir la gestion', 'https://espaces-partages.underwave.fr/#admin');
end $$;
revoke execute on function public.alerte_equipe(text, text) from public, anon, authenticated;

create or replace function public.alerte_a_valider() returns trigger
language plpgsql security definer set search_path = public as $$
declare quoi text; titre text;
begin
  if new.status <> 'en_attente' or (tg_op = 'UPDATE' and old.status = 'en_attente') then return null; end if;
  if tg_table_name = 'lieux' then quoi := 'un lieu'; titre := new.nom;
  elsif tg_table_name = 'annonces' then quoi := 'une annonce'; titre := new.titre;
  else quoi := 'un récit « Né ici »'; titre := new.titre; end if;
  perform public.alerte_equipe('À valider : ' || quoi || ' « ' || titre || ' »',
    'Bonjour,' || E'\n\n' || 'Une nouvelle publication attend votre validation sur Espaces Partagés : ' || quoi || ' « ' || titre || ' ».');
  return null;
end $$;
drop trigger if exists lieux_alerte on public.lieux;
create trigger lieux_alerte after insert or update of status on public.lieux for each row execute function public.alerte_a_valider();
drop trigger if exists annonces_alerte on public.annonces;
create trigger annonces_alerte after insert or update of status on public.annonces for each row execute function public.alerte_a_valider();
drop trigger if exists neici_alerte on public.neici;
create trigger neici_alerte after insert or update of status on public.neici for each row execute function public.alerte_a_valider();

create or replace function public.alerte_signalement() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'reports' then
    perform public.alerte_equipe('Nouveau signalement sur Espaces Partagés',
      'Bonjour,' || E'\n\n' || 'Un signalement vient d’être envoyé (' || new.target || '). Il est à traiter dans la gestion du répertoire.');
  else
    perform public.alerte_equipe('Nouvelle demande ALT : « ' || new.projet || ' »',
      'Bonjour,' || E'\n\n' || 'Une nouvelle demande pour parler d’un projet sur ALT vient d’arriver : « ' || new.projet || ' ».');
  end if;
  return null;
end $$;
drop trigger if exists reports_alerte on public.reports;
create trigger reports_alerte after insert on public.reports for each row execute function public.alerte_signalement();
drop trigger if exists alt_alerte on public.alt_demandes;
create trigger alt_alerte after insert on public.alt_demandes for each row execute function public.alerte_signalement();
