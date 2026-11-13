-- =====================================================================
-- Espaces Partagés : nettoyage automatique, chaque 1er du mois à 4 h
-- (ce que promet la politique de confidentialité)
-- À exécuter une fois, après 03-alertes.sql.
-- =====================================================================

create extension if not exists pg_cron;

alter table public.profiles add column if not exists prevenu_inactivite timestamptz;

create or replace function public.nettoyage_mensuel() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  -- Annonces : supprimées un an après leur mise en ligne
  delete from public.annonces where created_at < now() - interval '1 year';
  -- Signalements traités : supprimés au bout d'un an
  delete from public.reports where status = 'traite' and created_at < now() - interval '1 year';
  -- Journal des e-mails envoyés par l'équipe : gardé un an
  delete from public.emails where created_at < now() - interval '1 year';

  -- Comptes revenus après un e-mail de prévenance : on oublie la prévenance
  update public.profiles p set prevenu_inactivite = null
    from auth.users u
    where u.id = p.id and p.prevenu_inactivite is not null and u.last_sign_in_at > p.prevenu_inactivite;

  -- Comptes inactifs depuis 3 ans : e-mail de prévenance
  for r in
    select p.id, p.email, p.name from public.profiles p join auth.users u on u.id = p.id
    where not p.is_admin and p.prevenu_inactivite is null and coalesce(p.email, '') <> ''
      and coalesce(u.last_sign_in_at, u.created_at) < now() - interval '3 years'
  loop
    perform public.envoyer_email(r.email,
      'Votre compte Espaces Partagés sera supprimé dans 30 jours',
      'Bonjour,' || E'\n\n' || 'Vous ne vous êtes pas connecté·e à Espaces Partagés depuis plus de 3 ans. '
      || 'Comme le prévoit notre politique de confidentialité, votre compte, vos fiches et vos messages seront supprimés dans 30 jours.'
      || E'\n\n' || 'Pour garder votre compte, il suffit de vous connecter avant cette date.',
      'Me connecter', 'https://espaces-partages.underwave.fr/#connexion');
    update public.profiles set prevenu_inactivite = now() where id = r.id;
  end loop;

  -- Prévenus il y a plus de 30 jours et toujours pas revenus : compte supprimé (fiches, annonces, messages avec)
  delete from auth.users u using public.profiles p
    where p.id = u.id and not p.is_admin and p.prevenu_inactivite < now() - interval '30 days'
      and coalesce(u.last_sign_in_at, u.created_at) < p.prevenu_inactivite;
end $$;
revoke execute on function public.nettoyage_mensuel() from public, anon, authenticated;

-- Planification : le 1er de chaque mois à 4 h (heure UTC)
select cron.unschedule('nettoyage-mensuel') where exists (select 1 from cron.job where jobname = 'nettoyage-mensuel');
select cron.schedule('nettoyage-mensuel', '0 4 1 * *', 'select public.nettoyage_mensuel()');
