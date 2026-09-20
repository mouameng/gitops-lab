gateway/workload-dev

Objectif :
Publier le cluster workload-dev derrière Traefik.

Le routage des applications est effectué
par Ingress-NGINX dans le cluster workload-dev.

La Gateway ne référence aucune application
individuellement.

Applications attendues :

- whoami.dev.local
- gitea.dev.local
- vault.dev.local
- keycloak.dev.local

Toute nouvelle application exposée dans
workload-dev doit être publiée via
Ingress-NGINX sans modification de la Gateway.
