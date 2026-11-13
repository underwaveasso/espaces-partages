# Espaces Partagés

Répertoire culturel marseillais · collaboratif, porté par l'association Underwave.
En ligne : https://espaces-partages.underwave.fr

- `index.html` : tout le site (pages, styles et code).
- `img/` : visuel de partage et plan de Marseille.
- `vendor/` : bibliothèques hébergées sur le site (carte Leaflet, client Supabase, police Inter Tight), pour qu'aucun service tiers ne reçoive l'adresse des visiteurs.
- `supabase/` : structure de la base de données. À exécuter dans l'éditeur SQL de Supabase : `schema.sql`, puis `02-complements.sql`.

Les comptes et les données sont gérés par Supabase (région Paris). La clé présente dans `index.html` est la clé publique : les règles d'accès sont appliquées par la base elle-même.
