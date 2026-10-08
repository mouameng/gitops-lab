# GitOps Lab : capitalisation du PRA multi-clusters

**État documenté : 5 octobre 2026, après le second exercice destructif à trois clusters.**
**Statut : PRA du lab validé sur l’exécution observée ; correctif de démarrage Argo CD éprouvé sur reconstruction neuve.**
Ce document conserve les photographies et séquences historiques du 4 et du 5 octobre. Les mentions « non exécuté », « à faire » ou « avant premier PRA » dans les sections historiques décrivent leur point d’arrêt initial et ne sont pas l’état courant. La section 0 ci-dessous fait foi pour le résultat du PRA ; les autres limites du lab restent inchangées.

## 0. Mise à jour du PRA : incident Argo CD, correction et validation

### 0.1 Premier exercice : reconstruction fonctionnelle, accès Argo CD en boucle

Le premier PRA destructif a été exécuté et les parcours applicatifs ont fonctionné, mais l’accès à `argocd.local` bouclait avec `HTTP 307` / `ERR_TOO_MANY_REDIRECTS`. Un appel à `https://argocd.local/` redirigeait vers cette même URL. Le test direct, par `kubectl port-forward svc/argocd-server 18080:80` puis `curl` sur `http://127.0.0.1:18080/` avec `Host: argocd.local`, renvoyait lui aussi `307` vers `https://argocd.local/` : la redirection provenait du serveur Argo CD, et non uniquement de Traefik.

Le Deployment et le pod référençaient `ARGOCD_SERVER_INSECURE` depuis `argocd-cmd-params-cm/server.insecure`, avec `optional=true`, mais `printenv ARGOCD_SERVER_INSECURE` dans le conteneur échouait (code 1). Le ConfigMap affichait pourtant ensuite `server.insecure=true`. Le manifeste d’installation Argo CD v3.5.3, vérifié par empreinte, créait ce ConfigMap **sans données** ; la configuration `server.insecure: "true"` était versionnée séparément dans `applications/argocd/argocd-cmd-params-cm.yaml`. Le bootstrap installait et attendait Argo CD avant que cette configuration GitOps soit appliquée. Le scénario est cohérent avec un pod démarré avant la présence de la clé facultative ; l’instant précis d’ajout de la clé lors du premier exercice n’a pas été mesuré indépendamment.

Un `rollout restart deployment/argocd-server` manuel, suivi d’un `rollout status`, a produit un conteneur où `printenv ARGOCD_SERVER_INSECURE` renvoyait `true`. Après un premier `curl` transitoirement expiré, `https://argocd.local/` a répondu `HTTP/2 200`. Ce dépannage rétablissait l’accès mais ne suffisait pas à rendre le prochain PRA autonome.

### 0.2 Correctif versionné dans `bootstrap-management.sh`

Le correctif a été publié seul sur `main` au commit `9d57dbe` (`fix(pra): load Argo CD server config during bootstrap`). Il modifie `scripts/bootstrap-management.sh`, sans modifier le manifeste d’installation externe ni les secrets :

1. Le script calcule `ROOT_DIR` depuis son propre emplacement, pour référencer sans dépendre du répertoire courant le fichier Git `applications/argocd/argocd-cmd-params-cm.yaml`.
2. Il mémorise si `argocd-server` était absent et si une installation neuve a été lancée (`ARGOCD_FRESH_INSTALL`). Après l’application du manifeste Argo CD, il applique explicitement le ConfigMap versionné, avant de déclarer le serveur disponible.
3. **Uniquement en installation neuve**, il exécute `rollout restart deployment/argocd-server` puis `rollout status --timeout=300s`. Le redémarrage est nécessaire car le premier pod a pu démarrer avec le ConfigMap vide ; une variable d’environnement d’un pod existant n’est pas rechargée par l’application ultérieure du ConfigMap.
4. Après les attentes des Deployments serveur et repo-server, il lit `ARGOCD_SERVER_INSECURE` dans le conteneur et exige exactement `true` ; une lecture impossible ou une autre valeur arrête le script avec un message `[STOP]`. Le message `[OK]` n’est émis qu’après ce contrôle. Si Argo CD était déjà installé, le ConfigMap est appliqué et la valeur est vérifiée, mais aucun redémarrage automatique n’est fait dans cette branche.

Avant publication, `bash -n` et `git diff --check` ont réussi ; l’index du commit était limité au seul script. La réussite sur reconstruction neuve est documentée ci-dessous, distinctement de ces contrôles statiques.

### 0.3 Second exercice destructif : preuves de validation

Le prévol a réussi sur `main` à `9d57dbe`, identique à `origin/main` ; la sauvegarde de clé, le manifeste Argo CD, la limite inotify à 512, les destinations Git et la propreté des fichiers suivis ont été contrôlés. Le document `docs/gitops-lab-capitalisation-PRA-multicluster-2026-10-05.md` était alors non suivi et n’a pas été inclus dans le commit automatique. Le menu a affiché exactement `gitops-management`, `gitops-dev` et `gitops-prod` ; le choix destructif `2` a été saisi. Les trois clusters ont été supprimés puis recréés, avec leurs nœuds `Ready`.

Sur le management neuf, le manifeste Argo CD a été appliqué, le ConfigMap versionné configuré, puis le script a redémarré **lui-même** `argocd-server`. Le rollout a réussi et le journal a confirmé `[OK] ArgoCD disponible avec ARGOCD_SERVER_INSECURE=true`, sans intervention manuelle. La clé Sealed Secrets a été restaurée et comparée à la sauvegarde ; les deux SealedSecrets historiques ont été validés comme déchiffrables. Des candidats d’enregistrement neufs ont été générés et validés pour dev/prod, puis publiés sur `main` au commit `5b6c82f241c6a0c8c1b6ea7e847fa4d5b6b61bf6` (`chore(pra): renew workload registrations`). Le script a confirmé la conformité du commit aux candidats, la synchronisation de `cluster-registration` sur ce commit et la présence des deux Secrets de cluster avant de déclarer la Root App.

Les Deployments Whoami et les contrôleurs Ingress dev/prod ont terminé leurs rollouts. Les IP Ingress vérifiées étaient `172.18.250.200` (dev) et `172.18.255.200` (prod). Les réponses `HTTP 200` de `whoami.dev.local` et `whoami.prod.local` ont été associées respectivement aux pods `whoami-b494fb7c8-5lb4w` sur `gitops-dev` et `whoami-b494fb7c8-9wj7m` sur `gitops-prod`, vérifiés sur leurs clusters. Les captures fournies montrent l’interface et la page de connexion Argo CD accessibles ; la liste affichait 19 applications Synced et 19 Healthy. Le test direct `HTTP/2 200` de `argocd.local` cité plus haut appartient au **premier exercice après dépannage** ; aucun second résultat `curl` chiffré pour cette URL n’a été fourni après le second exercice. L’accès par navigateur et le contrôle de variable dans le bootstrap constituent les preuves disponibles pour le second.

**Qualification :** PRA du lab validé pour la reconstruction management/dev/prod, le renouvellement des accès, la reprise GitOps et les parcours HTTP dev/prod. Le correctif Argo CD a été éprouvé dans le second exercice sans redémarrage manuel. Les avertissements `metadata.finalizers` lors du dry-run et de la création de la Root App n’ont pas empêché l’exécution ; ne pas retirer le finalizer pour supprimer ces avertissements, car cela modifierait la suppression en cascade. L’indication navigateur « Non sécurisé » reste un sujet distinct de confiance TLS non vérifié ici. Les autres limites historiques (IPAM/L2 global, privilèges, CI, futurs environnements et persistance inotify après redémarrage WSL) ne sont pas déclarées résolues par cet exercice.

**Suite documentaire et Git :** le commit PRA `5b6c82f` publie les enregistrements renouvelés, pas cette mise à jour documentaire. Versionner le document révisé séparément avant de créer un tag et une release ; aucun tag ou release nouveau n’est attesté dans les éléments fournis.

## 1. Objectif et périmètre

Le lab GitOps doit pouvoir être détruit et reconstruit régulièrement, avec un parcours simple et automatisé : une confirmation uniquement si des clusters du périmètre existent, puis création des clusters, restauration de la clé, renouvellement des accès Argo CD, publication Git, réconciliation et preuves applicatives. L'intervention manuelle n'est recherchée qu'en cas d'erreur. Le PRA est un exercice local Kind/WSL, non une procédure de production.

Le dépôt `gitops-lab` et la branche `main` sont la source GitOps retenue. L'inventaire `clusters/workloads.tsv` est la source de la liste des clusters workload. Il comporte trois colonnes séparées par de **vraies tabulations** : `environment`, `kind_cluster`, `argocd_cluster`. L'état actuel est `dev / gitops-dev / workload-dev` et `prod / gitops-prod / workload-prod`. Le management `gitops-management` est traité séparément. Les clusters de test `gitops-management-test` et `gitops-workload-test` sont hors périmètre destructif.

Environnements envisagés : dev, intégration, recette, qualification, préproduction et prod. À ce jour, seuls dev et prod sont inventoriés et opérationnels. L'ajout d'une ligne au TSV ne crée pas à lui seul configuration Kind, AppProjects, pool MetalLB, applications Argo CD, gateway ou overlays. Les plages intermédiaires `172.18.251.*` à `172.18.254.*` ont été envisagées pour de futurs environnements, **sans attribution précise décidée**.

Les releases historiques rapportées sont v1.0.0, v1.1.0 et v1.1.1. Le PRA antérieurement validé concernait l'ancienne architecture à deux clusters ; il ne valide pas l'architecture actuelle à trois clusters. La future CI GitLab, la construction d'une image unique et sa promotion par digest restent des projets distincts.

## 2. Architecture actuelle et adressage

- Management Kind `gitops-management` : Argo CD, Traefik, cert-manager et Sealed Secrets.
- Workload Kind `gitops-dev`, enregistré auprès d'Argo CD sous `workload-dev`. Son Ingress-NGINX demande `172.18.250.200`, hôte Whoami `whoami.dev.local`.
- Workload Kind `gitops-prod`, enregistré sous `workload-prod`. Son Ingress-NGINX demande `172.18.255.200`, hôte `whoami.prod.local`.
- Traefik sur management relaie vers les noms des nœuds Kind correspondants ; les routes dev/prod et l'identité des pods répondants ont été vérifiées sur les clusters **existants**.
- Les Services Ingress diffèrent de nom : `ingress-nginx-controller` sur dev et `ingress-nginx-prod-controller` sur prod. Le label commun `app.kubernetes.io/name=ingress-nginx` permet de les retrouver ; il faut filtrer le Service de type `LoadBalancer`, et non le Service d'admission `ClusterIP`.

Le réseau Docker Kind observé est `172.18.0.0/16`. Les conventions MetalLB ne constituent pas une réservation IPAM Docker ; l'absence globale de collision n'a pas été démontrée par un audit réseau indépendant. Le contrôle HTTP par IP MetalLB seule ne prouve pas l'identité du cluster si deux clusters annoncent accidentellement la même IP.

### Organisation du dépôt pertinente pour le PRA

- `clusters/workloads.tsv` : inventaire workload, sans colonne IP.
- `clusters/management/kind-config.yaml` et `clusters/workload-<environment>/kind-config.yaml` : configurations Kind.
- `clusters/management/root-app/root-app.yaml` : Root App, source `main`, chemin `argocd`.
- `clusters/management/cluster-registration/<argocd_cluster>-sealedsecret.yaml` : enregistrements chiffrés suivis par Git.
- `argocd/applications/cluster-registration.yaml` : Application enfant, source `main`, chemin `clusters/management/cluster-registration`, synchronisation automatique avec `prune` et `selfHeal`.
- `argocd/applications/ingress-nginx*.yaml` : applications Ingress, IP demandée via `metallb.io/loadBalancerIPs` dans les valeurs Helm et destination par nom Argo CD.
- `argocd/applications/<argocd_cluster>-cluster.yaml` et `applications/clusters/<argocd_cluster>/` : routes gateway spécifiques aux workloads actuels.
- `applications/whoami/base/` et `applications/whoami/overlays/<environment>/` : application commune et Ingress par environnement.
- `scripts/bootstrap-platform.sh`, `bootstrap-management.sh`, `bootstrap-workload.sh`, `validate-registration-candidates.sh` et `bootstrap-gitops-sync.sh` : scripts de reprise et de contrôle.

## 3. Historique préservé : évolution de la plateforme

### 3.1 Création de prod et clé de scellement

Le lab partait d'un management et de l'ancien workload `gitops-lab`. La première création de `gitops-prod` a échoué à la préparation des nœuds. Le conteneur conservé montrait `Failed to create control group inotify object: Too many open files`, sortie 255, sans preuve d'OOM. Le relèvement temporaire de `fs.inotify.max_user_instances` de 128 à 512 a permis la création du cluster et l'observation du nœud Ready.

Une sauvegarde locale plus ancienne (`sealed-secrets-key7sctf`) ne correspondait pas à la clé active. La clé active `sealed-secrets-keyx9rjr` du 29 septembre a été sauvegardée hors Git dans `~/.config/gitops-lab/sealed-secrets-keyx9rjr-2026-09-29.yaml`, avec permissions 600. La cohérence certificat/clé privée et les données encodées ont été comparées sans exposer la clé. Par la suite, la restauration de cette clé **sur `gitops-management-test`** avant le démarrage du contrôleur a été testée : les SealedSecrets historiques dev/prod étaient déchiffrables sur ce management isolé. Cela ne remplace pas une restauration pendant le PRA réel.

Un jeton propre à prod a été créé, scellé et validé ; le commit `5752192` a publié l'enregistrement et les autorisations AppProject nécessaires. Les statuts de l'Application et le Secret Argo CD de type cluster ont été observés. Le test `/readyz` depuis management prouvait la joignabilité de l'API, non à lui seul l'authentification Argo CD ; le déploiement ultérieur de composants sur prod a fourni une preuve plus forte.

### 3.2 Adressage, routage et overlays

Le pool MetalLB dev est passé de `.255` à `.250` (commit `83f6f98`) et le Service Ingress a obtenu `172.18.250.200` après réconciliation. L'ancien nom DNS `ingress.workload-dev.lab.local` pointait encore vers `.255.200`, provoquant HTTP 502 ; un routage provisoire via le nom du nœud Kind a restauré HTTP 200 (commit `34de40d`). MetalLB prod, son pool `.255`, Ingress-NGINX prod et la route Traefik prod ont ensuite été publiés par jalons (`9f1afe8`, `950a5ea`, `e2ede80`, `42ddd3b`).

Whoami dev a été migré vers une base Kustomize et un overlay dev après comparaison normalisée des rendus (`0a55c74`). MetalLB a été structuré en base commune L2Advertisement et pools propres aux overlays (`9f3090b`). Whoami prod a été déployé depuis la même base avec son propre Ingress (`eeaadce`). La présence d'un statut `Synced/Healthy` a été complétée par des contrôles de Deployments, Services, IP et HTTP ; elle n'a jamais été considérée comme une preuve suffisante à elle seule.

### 3.3 Renommage du workload dev

`gitops-dev` a été créé parallèlement à l'ancien `gitops-lab`. Un nouvel accès Argo CD et un SealedSecret `workload-dev` ont été générés pour le nouveau cluster et publiés (`ea3a519`). Les Applications dev ont initialement affiché `Synced/Healthy` alors que le nouveau cluster était encore vide. L'Ingress-NGINX a rencontré un Secret d'admission absent ; une synchronisation complète a exécuté le Job de création, puis le contrôleur est devenu disponible. Le test du nom de pod renvoyé par Whoami a établi que le trafic arrivait bien sur `gitops-dev`. La gateway a été basculée vers `gitops-dev-control-plane` (`530b109`). L'ancien cluster `gitops-lab` a ensuite été supprimé ; le dépôt et le dossier `~/.config/gitops-lab` n'ont pas été renommés. Les parcours dev et prod ont été contrôlés après suppression.

### 3.4 Essai isolé de restauration et reprise GitOps

`gitops-management-test` et `gitops-workload-test` ont été créés sans supprimer les trois clusters actifs. Argo CD v3.5.3 a été installé depuis le manifeste local dont l'empreinte SHA-256 attendue est `7efe2d6bbc03f63623640f1e4198f16c84009d510fb810ef71e56df1b7614ba9`. La clé sauvegardée a été restaurée avant Sealed Secrets ; les deux SealedSecrets historiques ont passé `kubeseal --validate` sur ce management de test.

Un compte de service et un jeton ont été créés uniquement sur le workload de test. Le SealedSecret `workload-test` a produit un Secret Argo CD portant le label `cluster` et une ownerReference vers son SealedSecret. L'Application Whoami de preuve ciblait le workload de test, pas le management ; le Deployment y a atteint 3/3. Un dépôt Git minimal servi temporairement a permis à l'Application `registration-gitops-test` de reprendre ce SealedSecret, sans `prune`. Le dépôt bare existe encore localement au commit `8b93a1e...`, mais son service `git://...:9418` refusait ensuite la connexion. Les statuts `Synced/Healthy` affichés après son arrêt ne démontraient pas une lecture Git actuelle. La CLI Argo CD en mode core a nécessité le namespace `argocd` dans un kubeconfig temporaire ; la liste affichait `workload-test` sans statut de connexion explicite, tandis que l'Application Whoami indiquait une opération passée réussie. Cet essai ne valide pas la transition dev/prod lors d'une reconstruction complète.

### 3.5 Journal historique détaillé, conservé de la capitalisation initiale

Les sous-sections qui suivent restituent les **séquences observées à leur époque**. Lorsqu'elles parlent d'un script encore bloqué ou d'un fichier non publié, il s'agit d'un état historique, remplacé par l'état publié de la section 5. Cette distinction évite de perdre les diagnostics utiles tout en évitant de réutiliser une ancienne consigne devenue fausse.

#### Création initiale de `gitops-prod` : échec Kind et diagnostic

**Objectif de l'époque.** Ajouter prod sans supprimer le management ni l'ancien dev. La configuration `clusters/workload-prod/kind-config.yaml` avait été copiée de la configuration dev. Une première tentative de création s'est arrêtée pendant `Preparing nodes`, avec un message Kind indiquant qu'une ligne de démarrage systemd attendue n'avait pas été trouvée. Une tentative avec conservation du conteneur a permis de distinguer la cause : `docker inspect` indiquait un conteneur sorti avec le code 255 et `OOMKilled=false` ; les logs du conteneur mentionnaient l'échec de création d'un objet cgroup inotify, `Too many open files`. Il n'y avait donc pas de preuve d'une panne mémoire.

**Correction et validation historiques.** La valeur hôte `fs.inotify.max_user_instances` était à 128. Après son passage temporaire à 512, le cluster Kind échoué a été supprimé puis recréé ; son nœud a été observé `Ready`. Les contrôles utilisés incluaient la liste Kind, l'état et les logs du conteneur Docker, les deux paramètres `fs.inotify.max_user_instances` et `fs.inotify.max_user_watches`, puis l'état du nœud via le contexte explicite `kind-gitops-prod`. La persistance de la valeur n'était pas établie à cette étape ; l'incident après redémarrage WSL et la création du fichier sysctl sont décrits en section 7.

#### Sauvegarde de la clé et premier enregistrement prod

**Écart découvert.** Le fichier local générique `~/.config/gitops-lab/sealed-secrets-key.yaml` contenait l'ancienne clé `sealed-secrets-key7sctf` du 19 septembre ; son empreinte ne correspondait pas à la clé active `sealed-secrets-keyx9rjr` du 29 septembre. Une sauvegarde datée distincte de la clé active a été créée hors Git en mode 600. Les parties publiques du certificat et de la clé privée ont été comparées, puis les champs encodés `tls.crt` et `tls.key` ont été comparés avec ceux du Secret actif. L'identité, le namespace `sealed-secrets`, le type `kubernetes.io/tls` et le label de clé active ont été vérifiés. Les métadonnées de l'ancien cluster ne devaient pas être réappliquées telles quelles ; une projection limitée aux champs nécessaires a été préparée. La restauration effective n'a été démontrée que plus tard sur le management de test.

**Enregistrement prod.** Un ServiceAccount `argocd-manager`, un ClusterRoleBinding vers `cluster-admin` et un Secret de jeton ont été créés sur `gitops-prod`, après contrôle préalable du manifeste. Le candidat SealedSecret `argocd/workload-prod` a été produit hors Git, vérifié sur son identité, son label de Secret `cluster`, son format et ses permissions, puis validé par `kubeseal --validate`. Le commit ciblé `5752192` a publié ce SealedSecret et les autorisations des AppProjects. La synchronisation du SealedSecret, le Secret Argo CD résultant et la joignabilité de l'API prod ont été observés. Le simple `/readyz` ne validait pas les droits du jeton ; le déploiement de MetalLB sur prod a apporté une preuve opérationnelle complémentaire. La question du moindre privilège reste ouverte ; `cluster-admin` correspond au choix du lab.

#### Déplacement du pool dev et analyse du HTTP 502

**Modification préparée.** Le pool dev a été déplacé de la plage `.255.200-250` vers `.250.200-250`. Les valeurs Helm d'Ingress-NGINX demandaient explicitement `172.18.250.200` via l'annotation MetalLB. Le pool et l'Application Ingress ont été soumis à des contrôles de rendu et de dry-run avant le commit ciblé `83f6f98`.

**Écart observé après publication.** L'Ingress demandait la nouvelle IP, mais MetalLB affichait encore l'ancien pool et un événement `AllocationFailed`. La révision effectivement observée pour l'Application enfant de configuration MetalLB était encore l'ancienne `d2c8755`, malgré un statut initial `Synced/Healthy`. Après réconciliation/rafraîchissement de cette Application, le pool et le Service ont affiché `.250.200`. Le test direct de l'Ingress avec le bon en-tête Host répondait HTTP 200, alors que la gateway Traefik renvoyait HTTP 502 : depuis Traefik, l'ancien nom `ingress.workload-dev.lab.local` résolvait toujours vers `.255.200`.

**Correction historique.** Un test HTTP depuis le pod Traefik vers le nom du nœud `gitops-lab-control-plane:80` a répondu 200. La gateway a été provisoirement orientée vers ce nom Docker (`34de40d`), puis `whoami.dev.local` a retrouvé HTTP 200. Ce nom provisoire a été remplacé lors du renommage du workload dev. Un test direct de l'IP MetalLB ne suffisait pas à identifier le cluster en cas d'annonce concurrente ; l'identité du pod répondant a ensuite servi de preuve.

#### Migrations Kustomize : comparaison avant bascule de source

**Whoami dev.** La base `applications/whoami/base/` a reçu Namespace, Deployment et Service ; l'overlay dev a reçu son Ingress et les références Kustomize. Avant de changer le chemin de l'Application Argo CD, le rendu de l'overlay a été comparé aux quatre ressources initiales. Une différence initiale ne concernait que l'ordre des clés JSON ; une comparaison normalisée avec `jq -S -s` a confirmé l'équivalence du contenu. Le déplacement des fichiers et le nouveau chemin de l'Application ont été publiés ensemble (`0a55c74`), puis Application, Deployment 3/3 et HTTP 200 ont été contrôlés.

**MetalLB dev et prod.** Les deux annonces L2 initiales étant identiques, elles ont été placées dans une base commune ; les pools sont restés propres aux overlays. Le rendu dev a été comparé aux manifestes précédents avant publication (`9f3090b`) ; après réconciliation, pool `.250`, Service Ingress `.250.200` et Whoami HTTP 200 ont été observés. L'overlay prod a été comparé à un dossier provisoire, ensuite retiré ; il conservait le pool `.255.200-250` et la même annonce L2. Ce choix illustre la règle : partager ce qui est réellement commun, sans fabriquer des overlays pour des composants qui n'en ont pas besoin. Cert-manager est resté sur management pour `argocd.local`. Une future application configurable pourrait utiliser un ConfigMap pour les paramètres non sensibles et un Secret/SealedSecret pour les données sensibles ; Whoami n'a pas besoin d'un ConfigMap artificiel.

#### Mise en service prod par dépendances

L'ordre historique de publication a été : enregistrement et AppProjects (`5752192`) ; chart MetalLB (`9f1afe8`) avec contrôleur 1/1, speaker 1/1 et CRD vérifiées ; pool et annonce L2 (`950a5ea`) ; chart Ingress-NGINX (`e2ede80`) avec Service demandant puis recevant `.255.200` ; gateway management vers `gitops-prod-control-plane` et règle `*.prod.local` (`42ddd3b`) ; enfin Whoami prod depuis la base commune (`eeaadce`). Avant Whoami, Traefik atteignait l'Ingress et obtenait HTTP 404, ce qui confirmait la connectivité sans démontrer encore l'application. Après publication, le Deployment Whoami prod a atteint 3/3 et les deux hôtes dev/prod répondaient 200. Les sync waves ne remplacent pas les contrôles réels de chaque dépendance.

#### Renommage dev, admission Ingress et retrait de l'ancien cluster

Le nouveau `gitops-dev` a d'abord été créé en parallèle de `gitops-lab` ; l'ancien cluster servait encore le trafic. Un nouvel accès Argo CD et un candidat `workload-dev` ont été générés pour `gitops-dev`, l'ancien fichier ayant été sauvegardé hors Git avant remplacement ciblé (`ea3a519`). Le Secret Argo CD pointait alors vers `gitops-dev-control-plane:6443`.

Les Applications dev ont momentanément affiché `Synced/Healthy` alors que le nouveau cluster était vide. Après réconciliation, Whoami est apparu ; Ingress-NGINX restait à 0/1, avec `FailedMount` sur `ingress-nginx-admission` absent. Le rendu Helm prévoyait les Jobs d'admission `create` et `patch`, mais l'opération précédente n'avait pas exécuté ces Jobs. Une synchronisation complète a créé le Secret attendu. Une opération a signalé un délai de progression du Deployment dépassé, puis le contrôleur est passé 1/1. La solution retenue n'était pas de créer manuellement le Secret d'admission.

Pendant la transition, l'ancien et le nouveau dev annonçaient tous deux `.250.200`. Le test par IP seule était donc ambigu. Une requête avec le bon Host vers l'IP propre du nouveau nœud `172.18.0.5` a renvoyé le nom d'un pod de `gitops-dev`, puis le trajet depuis Traefik a été contrôlé. La gateway dev a été basculée vers `gitops-dev-control-plane` (`530b109`). Après vérification des deux hôtes, `kind delete cluster --name gitops-lab` a retiré l'ancien cluster. Les contrôles post-suppression montraient le Service dev à `.250.200`, la gateway sur le nouveau nom, trois pods Whoami dev prêts et une réponse HTTP provenant de l'un d'eux ; prod répondait également 200. **Ce retrait n'était pas un PRA complet.**

#### Photographie Git historique et transition vers les scripts publiés

Au commit `530b109`, les scripts `bootstrap-gitops-sync.sh`, `bootstrap-management.sh`, `bootstrap-platform.sh` et `bootstrap-workload.sh` étaient modifiés localement ; `clusters/workload-prod/kind-config.yaml`, `clusters/workloads.tsv` et un document de capitalisation étaient non suivis. Cette photographie explique les anciens avertissements « ne pas lancer » du document source. `bootstrap-gitops-sync.sh` a été transformé en contrôle de propreté du dépôt, sans publication implicite ; `bootstrap-management.sh` s'arrête après disponibilité d'Argo CD, sans Root App. Le script `bootstrap-workstation.sh` n'a pas été utilisé pendant ces contrôles. La branche distante `backup/main-before-pra-multicluster` a préservé `530b109`, puis `bb3216a` a publié les scripts et l'inventaire. Les commits ultérieurs `1fe668b` et `16e12b4` ont remplacé l'état « bloqué et non publié » : voir sections 5 et 6.

#### Risque historique des enregistrements suivis par Git

Sur le management actif, `cluster-registration` suit `main`, avec `prune=true` et `selfHeal=true`. La Root App suit aussi `main` et gère récursivement les Applications sous `argocd`. Les SealedSecrets `argocd/workload-dev` et `argocd/workload-prod` avaient un tracking ID de `cluster-registration` ; les Secrets Argo CD résultants avaient une ownerReference vers le SealedSecret correspondant. Une annotation sur `spec.template.metadata.annotations` n'est pas équivalente à une annotation sur `metadata` du SealedSecret. Retirer ces ressources de Git sans transition aurait pu entraîner la suppression des Secrets dépendants. Les anciens jetons sont déchiffrables avec la clé restaurée, mais pourraient ne plus authentifier des clusters recréés. D'où la décision actuelle : **ne pas activer la Root App du management reconstruit avant publication des nouveaux enregistrements sur `main` et synchronisation de `cluster-registration` sur le commit PRA**.

## 4. Décisions de conception prises après le document initial

1. **Un seul dépôt, `main` comme source GitOps.** La piste d'une branche PRA permanente ou d'un dépôt Git temporaire n'est pas retenue pour le lab. La Root App et `cluster-registration` continuent de suivre `main`.
2. **Automatisation du commit/push des enregistrements.** Après destruction et reconstruction, les nouveaux candidats sont validés, copiés vers les chemins dérivés du TSV, indexés explicitement, committés et poussés vers `origin/main`. Aucun `git add .` ni push forcé. La publication ne doit intervenir qu'une fois l'ancien management du périmètre détruit ; le script contrôle la branche `main`, l'alignement distant et l'absence de modifications suivies avant le menu destructif.
3. **Confirmation conditionnelle.** Si au moins un cluster Kind du périmètre existe, la liste exacte est affichée et le choix `2` est requis ; Entrée/`1` refuse. Si aucun cluster du périmètre n'existe, pas de question : on passe à la reconstruction. Les clusters `*-test` ne figurent pas dans l'inventaire et ne sont pas supprimés.
4. **Nombre de workloads piloté par `clusters/workloads.tsv`.** Les validations qui imposaient exactement dev/prod ont été remplacées par au moins un workload, avec colonnes, unicité et format des noms contrôlés. Les candidats et les chemins Git sont construits à partir de `argocd_cluster`. Le TSV ne contient ni IP, ni hôte HTTP.
5. **Candidats remplaçables après génération réussie.** `bootstrap-workload.sh` écrit le SealedSecret dans un temporaire dans le répertoire candidat, le valide auprès du contrôleur, puis renomme ce fichier sur le candidat final. Un échec avant le renommage conserve l'ancien candidat. Un fichier ordinaire préexistant n'est plus un motif de refus du prévol ; les liens symboliques et chemins de type inattendu sont refusés. Cela ne garantit pas la reprise automatique d'un PRA déjà partiellement reconstruit.
6. **Vérification du trafic, pas seulement d'Argo CD.** Après Root App, le script attend les Deployments Whoami et Ingress, le Service LoadBalancer, l'IP attendue déclarée dans l'Application Ingress, puis HTTP 200 et l'identité du pod répondant dans le cluster du TSV.

## 5. État Git et état d'exécution au point d'arrêt

Chronologie Git utile :

- `530b109` : état antérieur à la préparation multi-clusters ; sauvegarde distante `backup/main-before-pra-multicluster` créée à cette révision.
- `bb3216a` : préparation initiale des scripts, inventaire et configuration prod publiée sur `main`, avec verrous actifs.
- `1fe668b5b2628fea14584b3e5c2714640dfc58ae` : trois scripts de reprise mis à jour et publiés, **toujours verrouillés**.
- `16e12b43bfe4081be464964aa7251d7c9811561b` : déverrouillage coordonné de `bootstrap-platform.sh`, committé sur `main` et poussé. `main` local et `origin/main` ont été observés à cette même révision.
- Branche locale expérimentale `pra/registration-isolated` au commit `3d0d107` : uniquement le candidat `workload-test` ; ne pas le fusionner dans `main`.

**Dernière preuve avant l'exercice :** `bash scripts/bootstrap-platform.sh --preflight` sur `main` à `16e12b4` a renvoyé `code_retour=0`, après validation de la sauvegarde de clé, de l'inventaire et des fichiers Kind/GitOps, du manifeste Argo CD, de la limite inotify à 512, de l'alignement Git et des destinations d'enregistrement. Il s'est terminé par `[OK] Prévol terminé ; aucune action Kind ou Kubernetes appliquée`. Le fichier `docs/gitops-lab-capitalisation-PRA-multicluster-actualisee.md` était encore **non suivi** ; il n'a pas été inclus dans le commit de déverrouillage. Le présent fichier est un livrable documentaire distinct, à ne pas confondre avec une preuve de PRA.

**Clusters observés avant l'exercice :** `gitops-management`, `gitops-dev`, `gitops-prod`, `gitops-management-test`, `gitops-workload-test`. Les trois premiers sont dans le périmètre destructif ; les deux derniers ne le sont pas. **Aucune sortie d'exécution du parcours normal après confirmation `2` n'a été fournie à ce stade. Ne pas écrire que le PRA est réussi.**

## 6. Cinématique actuelle de `bootstrap-platform.sh`

Les étapes ci-dessous décrivent **le code publié et les tests préalables**, pas une exécution réussie de bout en bout. Le script `--plan` affiche les créations prévues sans agir ; `--preflight` réalise les vérifications puis quitte avant le menu. Attention : si la limite inotify est sous 512, `--preflight` peut la relever via `sudo -n sysctl -w` ; il n'est donc pas strictement sans effet sur l'hôte WSL. Un échec de `sudo -n` arrête avant destruction.

### 6.1 Avant toute destruction

- Vérifier le TSV : en-tête, trois colonnes tabulées, au moins une ligne workload, noms non vides, format et unicité de chaque colonne ; vérifier les configurations Kind. Les validations `--plan`, prévol et validateur ont été rendues cohérentes sur le nombre variable de workloads ; le générateur vérifie que le couple Kind/Argo CD existe dans le TSV.
- Vérifier la sauvegarde de la clé active hors Git : structure, namespace, type, label, certificat et clé privée cohérents ; ne pas afficher les données. Vérifier l'existence et l'empreinte du manifeste Argo CD versionné.
- Vérifier les prérequis GitOps actuels pour chaque environnement : fichier Kustomize Whoami, rendu `kubectl kustomize`, Application de route `<argocd_cluster>-cluster.yaml` et exactement un manifeste Ingress-NGINX ciblant `destination.name=<argocd_cluster>`. Ces contrôles n'englobent pas tous les composants possibles d'un futur environnement.
- Vérifier le répertoire hors Git des candidats. Un fichier candidat ordinaire existant est accepté ; un lien symbolique ou autre type est refusé. Vérifier `fs.inotify.max_user_instances >= 512`, avec ajustement local non interactif si nécessaire.
- Refuser un parcours normal hors branche `main`, si `HEAD` diffère de `origin/main`, si des fichiers Git suivis ou indexés sont modifiés, ou si une destination d'enregistrement est déjà modifiée/lien symbolique. Un document non suivi reste hors du commit automatique.
- Construire l'intersection entre les clusters Kind existants et `gitops-management` plus les noms Kind du TSV. N'afficher le menu que si cette intersection est non vide. Le choix `2` confirme le périmètre affiché ; `1` ou Entrée refuse. Ne pas lancer deux instances simultanément.

### 6.2 Suppression et reconstruction

- Supprimer seulement les noms présents dans l'intersection confirmée, puis vérifier qu'aucun cluster du périmètre n'est encore présent. Si la liste initiale est vide, la boucle de suppression est vide et la création suit sans confirmation. Les clusters de test ne sont pas dans cette liste.
- Créer `gitops-management`, attendre son nœud Ready, puis créer chaque workload du TSV avec sa configuration Kind et attendre son nœud Ready. La création Kind peut modifier le contexte kubectl actif ; les opérations Kubernetes du script utilisent des contextes explicites.
- Installer Argo CD sur le management neuf via `bootstrap-management.sh` et le manifeste local contrôlé, **sans Root App**. Vérifier l'API management, créer le namespace `sealed-secrets`, refuser une clé déjà présente, restaurer la clé depuis la sauvegarde projetée aux champs requis, comparer les données restaurées sans les afficher.
- Appliquer le projet `infrastructure` et l'Application Sealed Secrets ; attendre le contrôleur et les statuts de l'Application. Valider auprès du contrôleur les SealedSecrets historiques présents dans Git, sans appliquer leurs anciens jetons. Pour un environnement neuf sans historique, cette validation historique est sautée ; un lien symbolique historique est refusé.
- Pour chaque workload inventorié, `bootstrap-workload.sh` crée le ServiceAccount `argocd-manager`, le ClusterRoleBinding `cluster-admin` et un Secret de jeton sur **ce workload**, récupère le jeton, produit le Secret Argo CD dans un répertoire temporaire protégé, scelle le candidat hors Git et le valide avant remplacement du candidat final. `validate-registration-candidates.sh` contrôle identité et déchiffrement de chaque candidat ; cela ne démontre pas encore l'accès réel d'Argo CD.

### 6.3 Publication Git et reprise Argo CD

- Construire les chemins candidats et destinations à partir du TSV. Refuser candidat manquant/lien symbolique et destination modifiée/lien symbolique. Copier chaque candidat, comparer octet pour octet, puis `git add` **uniquement** les chemins d'enregistrement dérivés du TSV. Vérifier que tout fichier indexé appartient à cette liste. Un index vide après reconstruction provoque un arrêt plutôt qu'une fausse réussite ; un sous-ensemble de fichiers modifiés est accepté.
- Créer un commit d'enregistrements, pousser explicitement `HEAD:refs/heads/main` sans force, vérifier que la révision distante égale le commit publié et que le contenu de ce commit correspond à chaque candidat. Un échec du push arrête le script ; il ne faut pas activer la Root App sur d'anciens accès.
- Déclarer `cluster-registration` sur le management neuf après dry-run serveur ; attendre la révision synchronisée égale au commit PRA et l'état `Synced`. Attendre chaque Secret Argo CD et vérifier le label `argocd.argoproj.io/secret-type=cluster` ainsi que l'ownerReference vers le SealedSecret homonyme.
- Déclarer ensuite la Root App après dry-run serveur. **Une Application `Synced/Healthy`, une sync wave ou la simple présence d'un Secret ne prouvent pas à elles seules que les workloads sont prêts.**

### 6.4 Critères fonctionnels en fin de script

- Pour chaque ligne du TSV, attendre l'apparition du Deployment Whoami dans son namespace, puis `rollout status`. Le code a été corrigé pour ne pas supposer que le namespace existe déjà au premier appel.
- Retrouver le contrôleur Ingress-NGINX par label, exiger un résultat unique et attendre son rollout ; retrouver exactement un Service de type `LoadBalancer` et attendre son IP. Lire l'IP attendue depuis les valeurs Helm du manifeste Ingress dont `destination.name` correspond au nom Argo CD du TSV ; comparer à l'IP attribuée. Le TSV reste sans colonne IP.
- Rendre l'overlay Whoami pour lire l'hôte ; tenter le HTTP avec délai borné, conserver **le corps et le code d'une même requête réussie**, exiger HTTP 200, extraire `Hostname`, puis vérifier que le pod répondant est Ready sur le cluster Kind de la ligne. La convention actuelle suppose un overlay Whoami et un Deployment `whoami` par environnement ; elle devra être adaptée si les futurs environnements divergent.

### 6.5 Journal de mise au point des scripts : pourquoi chaque modification a été faite

Cette section détaille **le travail accompli depuis la version historique**, plutôt que de répéter le code Bash. Chaque jalon distingue l'intention, le changement et la preuve réellement observée. Le script final publié n'a pas encore été exercé de bout en bout.

#### Jalon A : stabiliser l'inventaire comme source unique des workloads

**Constat initial.** `clusters/workloads.tsv` comportait bien trois colonnes tabulées pour dev et prod ; un contrôle `awk -F '\t'` a retourné trois colonnes pour l'en-tête et chaque ligne. Deux validations de `bootstrap-platform.sh` imposaient pourtant explicitement les seuls couples dev/prod et exactement deux workloads. Le contrôle des chemins candidats utilisait également une liste fixe `workload-dev workload-prod`.

**Changement.** Les deux validations ont été ramenées à une structure correcte, des valeurs uniques, des noms au format attendu et **au moins un workload** ; la boucle des candidats parcourt désormais le TSV. Le validateur de candidats, déjà dynamique pour les noms, a reçu le même contrôle de format. `bootstrap-workload.sh` vérifie le couple `kind_cluster/argocd_cluster` par recherche dans le TSV, sans liste dev/prod. Les tests du couple `gitops-dev/workload-dev` et `gitops-prod/workload-prod` ont réussi ; `gitops-dev/workload-prod` a été refusé. Les sorties `--plan` et `--preflight` ont affiché les deux workloads actuels. Cela démontre le comportement avec l'inventaire actuel, **pas** l'ajout entièrement opérationnel d'un troisième environnement.

**Conséquence pour l'extension.** Une nouvelle ligne doit être accompagnée d'une configuration Kind, des destinations et Applications Argo CD, du pool MetalLB, de la gateway et de l'overlay applicatif. Le TSV ne porte pas les adresses IP. Les contrôles prédestruction vérifient la présence de la route, le rendu Kustomize et une Application Ingress unique ciblant le nom Argo CD. Les conventions de nommage et de Whoami restent celles du lab actuel.

#### Jalon B : confirmer uniquement ce qui sera réellement détruit

**Constat initial.** Le menu demandait une confirmation même lorsqu'aucun cluster du périmètre n'était présent. Le périmètre souhaité est le management plus les noms Kind issus du TSV, et non tous les clusters de la machine.

**Changement.** Le script calcule les clusters existants du périmètre et n'affiche le menu que si la liste est non vide. Une liste vide passe à la reconstruction. Le choix `2` ne supprime que les noms présents dans cette liste ; après suppression, un nouveau contrôle refuse de recréer tant qu'un cluster du périmètre subsiste. Les clusters de test restent hors de cette intersection.

**Preuves avant exercice.** Une simulation sans appel Kind a produit : aucun cluster → reconstruction sans question ; présence partielle → confirmation limitée à `gitops-dev` ; tous présents → confirmation management/dev/prod. Une lecture de l'état Kind réel a trouvé ces trois noms, sans `gitops-management-test` ni `gitops-workload-test`. Ce test de décision et la revue du code **ne prouvent pas encore** que les suppressions et créations s'enchaînent correctement pendant le PRA réel.

#### Jalon C : rendre le prévol utile avant le point destructif

Le prévol contrôle la clé sauvegardée sans afficher de matière privée, l'inventaire, les configurations Kind, le manifeste Argo CD local et son empreinte, les chemins candidats, puis la disponibilité des prérequis GitOps. Il rend chaque overlay Whoami avec `kubectl kustomize` et recherche une seule Application Ingress-NGINX dont `destination.name` correspond à chaque nom Argo CD inventorié. Ces contrôles ont passé pour dev/prod ; un essai hors contexte du script avait échoué sur un chemin `/applications/whoami/overlays/` parce que les variables n'étaient pas définies dans le shell interactif, sans constituer une panne de l'overlay. Le contrôle exécuté **dans** `--preflight` est passé.

Le prévol vérifie également la limite inotify. Après un `wsl --shutdown`, elle était revenue à 128 ; prod présentait `kube-proxy` en `CrashLoopBackOff`, deux CoreDNS non Ready et un contrôleur Ingress prod 0/1. Le log courant de `kube-proxy` montrait `fsnotify watcher init: too many open files`. Après relèvement à 512, `kube-proxy` s'est rétabli lors de ses propres tentatives, puis CoreDNS et Ingress sont redevenus Ready. Un fichier dédié `/etc/sysctl.d/90-gitops-lab-inotify.conf` a été créé avec la valeur 512. Le script tente désormais de relever la limite avant le menu, via `sudo -n` si elle est insuffisante, et s'arrête si cela échoue. **Le fichier persistant n'a pas encore été éprouvé par un nouveau redémarrage WSL.** Le mode `--preflight` peut donc modifier ce seul paramètre hôte si nécessaire, mais ne crée ni ne supprime de cluster.

Enfin, le prévol refuse une branche autre que `main`, une divergence entre `HEAD` et `origin/main`, un index ou des fichiers suivis modifiés, et des destinations d'enregistrement déjà modifiées ou de type lien symbolique. Ces contrôles ont été placés **avant** le menu, car les découvrir après destruction aurait rendu le PRA inutilement difficile à reprendre. Sur la branche `pra/multicluster-recovery`, le refus de branche a été observé avec code 1. Après avance rapide de `main` et publication du déverrouillage, le prévol complet a rendu code 0.

#### Jalon D : restauration de la clé avant le contrôleur

Le parcours écrit crée management et workloads, installe Argo CD **sans Root App**, puis restaure la clé dans le namespace `sealed-secrets` du management neuf. Il refuse une clé préexistante, limite les métadonnées appliquées, compare les champs restaurés à la sauvegarde, puis installe le projet `infrastructure` et l'Application Sealed Secrets. Il attend la création et le rollout du contrôleur, puis la synchronisation et la santé de l'Application. Une validation des SealedSecrets historiques présents dans Git est prévue **auprès du contrôleur reconstruit**, sans appliquer les anciens jetons. Pour un futur environnement sans fichier historique, cette validation est sautée ; les liens symboliques historiques sont refusés, y compris cassés.

Les deux fichiers historiques dev/prod ont passé `kubeseal --validate` sur le management **actuel**, et avaient déjà été validés sur le management de test après restauration de la clé. Le code du PRA complet a passé `bash -n`, mais sa restauration sur `gitops-management` recréé n'est pas encore observée. Si la clé a tourné depuis la sauvegarde datée, la capacité à déchiffrer les fichiers doit être réévaluée ; ne pas substituer silencieusement l'ancienne sauvegarde générique.

#### Jalon E : générer et remplacer les candidats hors Git

**Ancien comportement.** Le générateur refusait un `OUTPUT` déjà présent, ce qui bloquait une relance après un candidat résiduel. Un essai sur un couple valide avait confirmé ce refus avant toute création de ServiceAccount. L'utilisateur a retenu pour le lab un remplacement automatique, sans réutilisation aveugle de l'ancien jeton.

**Comportement préparé.** Le générateur exige explicitement les contextes et noms Kind/Argo CD, borne `OUTPUT` au répertoire candidat hors Git, refuse un lien symbolique et utilise `umask 077`. Sur le workload ciblé, il crée `argocd-manager`, son binding et le Secret de jeton, attend un jeton non vide, puis produit le Secret Argo CD dans un répertoire temporaire supprimé à la sortie. Le SealedSecret est d'abord écrit dans un fichier temporaire **dans le répertoire du candidat final**, validé par `kubeseal --validate`, puis renommé sur `OUTPUT`. Le nettoyage à la sortie supprime le temporaire s'il subsiste. Un ancien candidat ordinaire est donc conservé si la génération échoue avant le renommage. Le test local avec fichiers factices a montré `avant=ancien`, `apres=nouveau`. Il ne teste ni la création réelle d'un jeton ni le comportement complet du générateur modifié.

Le validateur de candidats contrôle pour chaque ligne du TSV l'identité du SealedSecret, son namespace et son déchiffrement. Son message final rappelle correctement que cela **ne teste pas l'accès Argo CD au workload**.

#### Jalon F : publier les enregistrements renouvelés sans embarquer d'autres fichiers

**Choix retenu.** Dans le parcours prévu, le management actif doit être supprimé avant que les nouveaux enregistrements soient poussés sur `main`, afin d’éviter une réconciliation prématurée. Cette séquence n’a pas encore été exécutée. Après génération et validation des candidats, le script calcule un chemin candidat et une destination Git par ligne du TSV. Il vérifie l'existence des candidats, refuse les liens symboliques et les destinations modifiées, copie les fichiers et compare les copies aux candidats.

**Bornage du commit.** Le script indexe uniquement les destinations calculées ; il vérifie ensuite que chaque fichier indexé appartient à la liste attendue. L'index peut contenir un **sous-ensemble** des chemins si seuls certains fichiers changent, mais aucun chemin extérieur. Un index vide après reconstruction est refusé : il ne serait pas prudent de déduire de l'absence de diff que de nouveaux jetons ont été publiés. Le commit est suivi d'un push explicite et non forcé vers `refs/heads/main`, d'une comparaison de l'empreinte distante et d'une comparaison du contenu de chaque chemin publié avec son candidat. Le document non suivi et les scripts ne sont pas inclus dans ce commit automatique.

**Preuves avant exercice.** La liste des noms TSV correspondait aux deux SealedSecrets suivis dans Git ; les chemins calculés étaient ceux de `workload-dev` et `workload-prod`. Un dépôt bare temporaire avec des fichiers factices a validé le mécanisme `add → commit → push → comparaison de révision` ; le message d'avertissement « cloned an empty repository » était normal au premier clone. Aucun nouveau SealedSecret dev/prod n'a encore été publié par **l'exécution intégrée du PRA**. Si un commit est créé localement mais que le push échoue, l'état Git doit être diagnostiqué avant une relance.

#### Jalon G : reprendre GitOps avant la Root App

La Root App et l'Application `cluster-registration` suivent toutes deux `main`. Le code applique d'abord `cluster-registration` sur le management neuf après un dry-run serveur, attend que sa révision synchronisée corresponde au commit PRA puis l'état `Synced`, et vérifie que chaque Secret de cluster porte le label Argo CD attendu et une ownerReference vers son SealedSecret. La structure de cette relation a été observée sur le management de test pour `workload-test` ; cela ne constitue pas une preuve de création des Secrets dev/prod après PRA. La Root App n'est déclarée qu'ensuite, après son dry-run. Cette séquence remplace la piste d'un dépôt ou d'une branche PRA durable, écartée pour conserver un lab facile à rejouer.

#### Jalon H : prouver le résultat sur les workloads et par HTTP

Le contrôle de fin de script attend, pour chaque workload, l'apparition du Deployment Whoami même si le namespace n'existe pas encore, puis son rollout. La première version de cette attente avait été mal assemblée, puis corrigée ; un test de sortie de boucle fondé sur `attempt > 60` a été remplacé par un contrôle réel de présence, car la dernière tentative vaut 60. Le contrôleur Ingress est découvert par label, pas par un nom dev/prod codé en dur. Le Service est filtré sur `type=LoadBalancer` afin d'exclure `*-admission`. L'IP réelle est comparée à celle des valeurs Helm de l'Application Ingress dont `destination.name` correspond au TSV. Les tests en lecture seule ont trouvé une seule Application par workload et une égalité entre les IP attendues et attribuées.

L'hôte Whoami est lu depuis le rendu de l'overlay. Le contrôle HTTP conserve le corps et le code d'**une même requête** afin que le `Hostname` extrait corresponde au HTTP 200 testé. Des tentatives bornées ont été ajoutées pour laisser le temps à la gateway de se stabiliser après reconstruction. Le nom de pod retourné est ensuite vérifié `Ready` sur le contexte Kind de la ligne. Le contrôle isolé dev a obtenu HTTP 200 à la première tentative et un pod Ready ; prod avait également répondu 200 avec un pod Ready. Ces tests ont porté sur les clusters existants, pas sur le résultat du PRA.

**Vigilance observée avant l'exercice.** L'Application `ingress-nginx-prod` était affichée `Synced/Healthy` alors que son contrôleur était 0/1 et redémarrait ; le diagnostic a révélé la limite inotify à 128 après redémarrage WSL. Après passage à 512, `kube-proxy`, CoreDNS et Ingress prod sont revenus Ready. Cette séquence confirme pourquoi la fin du PRA doit vérifier les objets et le HTTP, plutôt que le seul statut Argo CD.

#### Jalon I : publication du code et levée coordonnée des verrous

Le développement a eu lieu sur `pra/multicluster-recovery`, à partir de `bb3216a`. Le commit local `1fe668b` a contenu seulement `bootstrap-platform.sh`, `bootstrap-workload.sh` et `validate-registration-candidates.sh`, **avec trois arrêts encore actifs** : refus du parcours normal, refus du choix destructif `2`, et arrêt après validation des candidats. Il a été poussé vers `origin/main` sans inclure le document non suivi. Les cinq clusters Kind sont restés présents.

Pour le lab, un deuxième parcours PRA réservé aux clusters de test a été écarté comme trop lourd : les tests ciblés non destructifs ont couvert la décision de destruction, le remplacement local de candidat, la mécanique Git et les contrôles réseau sur les clusters existants. La branche locale `main`, initialement en retard, a été avancée rapidement jusqu'au commit publié. Son prévol a passé. Les trois arrêts ont alors été retirés **ensemble**, sans modifier la logique des contrôles ; le commit `16e12b4` a publié uniquement ce déverrouillage sur `main`. Un nouveau `--preflight` sur cette révision a renvoyé code 0. **Le choix destructif `2` n'a pas encore été saisi ; le premier PRA réel reste à observer.**

## 7. Validations effectivement réalisées avant le premier PRA

- Syntaxe Bash des trois scripts modifiés et `git diff --check` : réussis. Le commit verrouillé `1fe668b` ne contenait que les trois scripts ; le commit de déverrouillage `16e12b4` ne contenait que `bootstrap-platform.sh`.
- `--plan` : management, dev et prod affichés ; `--preflight` : réussi sur `main` publié, code retour 0. Sur la branche de développement, refus attendu avant le menu.
- Inventaire : trois colonnes tabulées vérifiées ; couples dev/prod acceptés, couple croisé refusé. Les validations et chemins candidats suivent désormais le TSV. Le prévol a rendu les overlays et trouvé une Application Ingress par destination actuelle.
- Candidats : `kubeseal --validate` des SealedSecrets historiques dev/prod réussi sur management actif ; restauration et validation sur management de test déjà observées. Remplacement d'un fichier candidat factice par renommage testé localement (`avant=ancien`, `apres=nouveau`) ; **le générateur modifié n'a pas été exécuté dans le PRA réel**.
- Git : commit/push et comparaison des révisions testés avec dépôt bare et fichiers factices locaux, sans push GitHub de ces données factices. La mécanique ne prouve pas l'exécution intégrée après reconstruction.
- IP Ingress : `.250.200` dev et `.255.200` prod correspondent aux valeurs des manifestes et aux Services actuels ; recherche automatique par `destination.name` : une correspondance pour chacun.
- HTTP actuel : dev et prod ont répondu 200 ; le `Hostname` retourné correspondait à un pod Ready dans le cluster respectif. La boucle de découpage de la réponse a été testée sur dev ; le trafic après reconstruction reste inconnu.
- Inotify : après `wsl --shutdown`, la valeur était revenue à 128 ; `kube-proxy` prod échouait avec `fsnotify watcher init: too many open files`, CoreDNS et Ingress étaient non Ready. Après passage manuel à 512, `kube-proxy` s'est rétabli automatiquement, puis CoreDNS et Ingress sont revenus Ready. Un fichier `/etc/sysctl.d/90-gitops-lab-inotify.conf` contenant `fs.inotify.max_user_instances = 512` a été créé et la valeur active contrôlée à 512. **La persistance après un nouveau redémarrage WSL n'a pas encore été vérifiée.** Le prévol peut corriger temporairement la valeur si `sudo -n` fonctionne.

## 8. Limites et conduite en cas d'échec du premier exercice

Le PRA destructif à trois clusters n'a pas encore eu lieu. La réussite du prévol n'est pas une preuve de restauration. Si le script s'arrête après suppression, **ne pas le relancer aveuglément** : relever la dernière étape réussie, les clusters réellement présents, les fichiers candidats hors Git, l'état de `main` local/distant, les Applications Argo CD et les Secrets sans en afficher les données. Le remplacement atomique d'un candidat simplifie la relance de sa génération, mais le script complet n'est pas démontré idempotent après une reconstruction partielle. Un commit local créé avant un push refusé peut aussi nécessiter une analyse Git avant une nouvelle tentative. Ne pas rétablir un ancien SealedSecret sans vérifier la validité de son jeton sur le cluster recréé.

Les accès `argocd-manager` utilisent `cluster-admin` dans ce lab ; la réduction des droits est une piste future, pas un prérequis à cet exercice. Les hooks/Jobs d'admission Ingress-NGINX avaient nécessité une synchronisation complète lors de la migration dev ; contrôler leur résultat si le rollout échoue. La source Git `main` contient les anciens SealedSecrets jusqu'au renouvellement après destruction ; la Root App ne doit pas être activée avant publication et reprise contrôlée des nouveaux enregistrements. Les statuts Argo CD anciens ou une source Git temporaire arrêtée ne sont pas des preuves d'accès courant.

Ne jamais publier dans Git ou dans cette documentation : clé privée Sealed Secrets, jeton de ServiceAccount, Secret déchiffré, données de `config` Argo CD. Les candidats chiffrés et la sauvegarde de clé ont des rôles différents ; la sauvegarde de clé reste hors Git. Le document Markdown local précédemment non suivi n'est pas inclus dans le commit automatique des enregistrements.

## 9. Reprise pratique et futurs clusters

**Point de reprise immédiat :** `main` local et `origin/main` ont été observés à `16e12b4`, prévol `code_retour=0`, trois clusters actifs plus deux clusters de test. Le prochain geste prévu est le lancement interactif de `bash scripts/bootstrap-platform.sh` sur `main`, avec vérification de la liste affichée avant saisie de `2`. **Ce geste est destructif pour management/dev/prod ; il n'a pas été exécuté dans les éléments disponibles.** Si la liste diffère du périmètre attendu, refuser. Ne pas exécuter une seconde instance simultanément. Consigner le premier arrêt éventuel et les preuves de chaque jalon.

Pour ajouter un environnement ultérieurement :

1. Définir une ligne TSV valide avec nom Kind et nom Argo CD uniques, ainsi que sa configuration `clusters/workload-<environment>/kind-config.yaml` ; le management reste hors TSV.
2. Préparer les destinations AppProject, les Applications GitOps, le pool MetalLB propre à l'environnement, le manifeste Ingress-NGINX et son IP déclarée, la route gateway et l'overlay Whoami. Vérifier le réseau Docker et les collisions IP avant de publier.
3. Rendre localement les overlays et vérifier la correspondance des destinations Argo CD. La convention actuelle du script attend une route `<argocd_cluster>-cluster.yaml`, un overlay `applications/whoami/overlays/<environment>`, un Deployment `whoami`, et une seule Application Ingress correspondant au nom Argo CD. Si l'environnement ne suit pas ces conventions, adapter explicitement le script et les critères fonctionnels avant de l'ajouter au PRA.
4. Publier ces prérequis GitOps **avant** l'exercice destructif. Le nouveau SealedSecret d'enregistrement peut être absent historiquement ; il sera généré puis publié après création du nouveau workload. Vérifier le déploiement réel, l'IP, HTTP et l'identité du pod, pas seulement `Synced/Healthy`.
5. Après réussite d'un exercice complet, mettre à jour ce journal avec commit PRA, étapes observées, erreurs et corrections, état Git final, disponibilité des clusters, IP et tests HTTP. Créer tag/release seulement après validation constatée.

## 10. Registre des points encore ouverts

| Sujet | État au point d'arrêt | Preuve attendue pour clôture |
|---|---|---|
| PRA trois clusters | Prévol réussi, script déverrouillé et publié ; exercice destructif non lancé | Suppression limitée au périmètre, reconstruction complète et contrôles fonctionnels réussis dans un même exercice |
| Clé Sealed Secrets | Sauvegarde et restauration isolée testées ; parcours réel non exécuté | Restauration sur management reconstruit, comparaison et déchiffrement historique confirmés |
| Enregistrements Argo CD | Génération, validation et publication automatisées dans le code ; non exécutées en PRA | Nouveaux jetons, commit distant vérifié, Secrets Argo CD et workloads effectivement déployés |
| Relance après échec partiel | Candidat remplaçable atomiquement ; parcours global non démontré idempotent | Analyse et procédure de reprise à partir d'un état partiel réellement observé |
| Inotify WSL | 512 actif et fichier sysctl.d créé | Valeur vérifiée après un nouveau redémarrage WSL ; récupération des composants si nécessaire |
| Réseau MetalLB | IP dev/prod attribuées et HTTP opérationnel | Absence de collision IPAM/L2 vérifiée sur l'ensemble du réseau partagé |
| Futurs environnements | Conventions et TSV extensibles ; seuls dev/prod préparés | Configurations Kind, GitOps, pools, routes et tests de bout en bout par environnement |
| CI et privilèges | CI/promotion par digest et moindre privilège non implémentés | Travaux dédiés après validation du PRA du lab |

**Règle de qualification (photographie préparatoire) :** les critères décrits ici ont été satisfaits lors du second exercice ; voir section 0 pour les preuves et les limites effectivement constatées. Le tableau ci-dessus conserve son état historique avant exercice.

## 11. Registre historique des actions, réconcilié avec l'état courant

Le document initial tenait un registre détaillé. Les identifiants ci-dessous sont conservés pour faciliter la reprise, mais leur **statut a été révisé** ; « codé » n'est pas « validé par un PRA complet ».

| ID | Action initiale | Situation au 5 octobre 2026 | Clôture attendue |
|---|---|---|---|
| PRA-01 | Renouveler les enregistrements Argo CD après recréation | Séquence génération → validation → commit/push `main` → Application `cluster-registration` codée ; essai isolé d'un seul enregistrement réalisé | Nouveau Secret par workload et déploiement réel après PRA |
| PRA-02 | Rendre le bootstrap de plateforme atteignable | Trois verrous retirés ensemble et publiés dans `16e12b4` ; prévol réussi | Parcours normal terminé sans arrêt imprévu |
| PRA-03 | Recréer management et workloads inventoriés | Boucles Kind et attente Ready codées ; suppression bornée au périmètre | Trois nœuds recréés et Ready pendant le même exercice |
| PRA-04 | Restaurer la clé active avant le contrôleur | Sauvegarde datée contrôlée, restauration sur management **de test** validée ; code de restauration réelle préparé | Clé restaurée et SealedSecrets historiques validés sur management reconstruit |
| PRA-05 | Respecter les dépendances GitOps | Ordre explicite Sealed Secrets → candidats → publication → `cluster-registration` → Root App codé | Révision synchronisée, Secrets de cluster et ressources workload observés |
| PRA-06 | Vérifier Ingress et ses hooks d'admission | Incident historique du webhook documenté ; contrôles de rollout, Service, IP et HTTP codés | Contrôleur, Secret/Jobs si nécessaires, Service et trafic fonctionnels après PRA |
| PRA-07 | Exécuter le PRA destructif trois clusters | **Non commencé** dans les preuves disponibles ; prévol `0` sur `16e12b4` | Journal complet de l'exercice, écarts, corrections et validation finale |
| ENV-01 | Pérenniser inotify à 512 | Fichier `/etc/sysctl.d/90-gitops-lab-inotify.conf` créé ; valeur active 512 ; prévol peut corriger | Vérification après un prochain redémarrage WSL |
| ENV-02 | Vérifier collisions IP MetalLB/Docker | IP dev/prod attribuées et joignables ; pas d'audit IPAM/L2 global | Contrôle de non-chevauchement pour les plages actuelles et futures |
| GIT-01 | Publier les scripts et configurations de manière ciblée | `bb3216a`, `1fe668b` et `16e12b4` publiés ; document local non suivi lors du dernier état | Document publié séparément si souhaité, après revue de son contenu |
| SEC-01 | Étudier des droits plus limités que `cluster-admin` | Choix actuel conservé pour le lab | Rôle réduit testé sans perte des opérations Argo CD nécessaires |
| DOC-01 | Transformer le journal en procédure éprouvée | Présent document exhaustif préparatoire ; résultat PRA manquant | Ajouter les sorties et incidents du premier exercice, puis versionner |
| SCALE-01 | Ajouter intégration, recette, qualification et préprod | Inventaire extensible ; dépendances GitOps non créées | Environnement ajouté, déployé et validé de bout en bout |
| CI-01 | Construire une fois, promouvoir le même digest | Non implémenté | Pipeline et tests de promotion vérifiés |
| OPT-01 | Étudier Metrics Server prod et ConfigMaps utiles | Non requis pour le premier PRA | Besoin confirmé avant toute modification |

### 11.1 Éléments à relever pendant le premier exercice

Pour permettre un retour d'expérience utile, noter la révision Git avant lancement, les noms Kind affichés au menu, l'heure et le résultat de chaque jalon majeur, le commit des SealedSecrets renouvelés, les états des Applications et les ressources effectivement disponibles. Si un jalon échoue, conserver **le premier message d'erreur utile** et l'état du système à cet instant ; ne pas recopier les valeurs des Secrets. Relever les IP attribuées et, pour chaque hôte Whoami, le code HTTP et le nom du pod répondant confirmé sur son cluster. Cette liste est un cadre de journalisation, non une affirmation que ces observations existent déjà.

### 11.2 Séparation des preuves

- **Historique de la plateforme :** déploiement initial prod, migrations d'overlays, renommage dev, retrait de `gitops-lab` et tests HTTP post-retrait.
- **Essai isolé :** restauration de clé et enregistrement `workload-test` sur deux clusters de test ; ne vaut pas PRA des trois clusters actifs.
- **Préparation du PRA actuel :** syntaxe, contrôles statiques, tests factices Git/fichiers, prévol sur `main` et HTTP sur clusters existants.
- **PRA validé :** catégorie remplie par le second exercice destructif, avec les preuves et réserves détaillées en section 0 ; la phrase initiale « catégorie encore vide » décrivait seulement le point d’arrêt historique.
