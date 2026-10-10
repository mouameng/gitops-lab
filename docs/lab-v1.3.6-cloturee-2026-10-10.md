## Lab Infrastructure DevOps — Clôture v1.3.6

**Date de clôture technique :** 10 octobre 2026
**Statut :** périmètre réalisé validé par un PRA complet ; deux points non confirmés (voir section 11)
**Dépôt principal Gitea :** platform/infrastructure-devops
**Dépôt de secours GitHub :** mouameng/infrastructure-devops
**Tag prévu :** v1.3.6 (sur le commit documentaire final)

### 1. Synthèse

La v1.3.6 devait démarrer la mutualisation de la CI de l'organisation games. Le chantier réellement mené et validé est préalable : harmoniser le nom des images de 2048 sous games/2048 et passer à des pulls privés authentifiés, restaurables au PRA. La mutualisation de la CI (scripts/games, games.tsv, release-dev.sh, promote-prod.sh, workflow commun) n'est pas réalisée et reste à faire.

Résultat :

- images de 2048 copiées de gitea.local/gitea_admin/2048 vers gitea.local/games/2048, digests conservés ;
- organisation games conservée privée ; lecture anonyme du registre refusée ;
- compte technique games-puller, limité à la lecture des packages ;
- Secret games-registry-pull créé sur dev et prod par le bootstrap, avant Argo CD ;
- socle et CI de games/2048 basculés sous le nouveau chemin ;
- PRA complet réussi (code retour 0), 26 Applications Synced/Healthy.

### 2. Périmètre

**Réalisé :**

- migration des images dev et prod vers games/2048 ;
- accès privé en lecture pour les workloads ;
- script scripts/ensure-games-pull-secret.sh et son intégration au bootstrap et au prévol ;
- inventaire du jeton dans scripts/external-deps.tsv ;
- bascule du socle (base et overlays) et de la CI games/2048 ;
- ajout de ci/test.sh dans games/2048 ;
- validation par PRA complet.

**Non réalisé (reporté) :**

- mutualisation de la CI games (scripts/games, games.tsv, release-dev.sh, promote-prod.sh, workflow commun) ;
- paramétrage de ci/set-overlay-digest.sh (IMAGE_NAME, SOURCE_REPOSITORY) : écarté, le script est désormais fixé sur games/2048 ;
- privatisation de platform et des copies GitHub ;
- renommage des dossiers locaux (~/.config/lab, ~/.local/share/lab) ;
- journalisation automatique du bootstrap.

### 3. Décisions

- **Organisation games privée.** Les images sont lues avec authentification, pas en accès anonyme.
- **Image sous games/2048.** Le package suit le nom du dépôt, pour éviter les confusions lors de futurs diagnostics. Fait avant l'arrivée d'un second jeu.
- **Copie sans reconstruction.** Les images existantes sont copiées avec Skopeo (--all --preserve-digests) ; un build identique donnerait un autre digest.
- **Identités séparées.** Lecture des images : games-puller. Publication : secret d'organisation REGISTRY_TOKEN. Écriture GitOps : ci-bot. Le jeton de publication n'est pas utilisé par les workloads.
- **Secret de pull créé par le bootstrap** depuis un jeton local hors Git, juste après la configuration du registre sur les nœuds workload, avant cluster-registration et la Root App. Pas de contrôleur Sealed Secrets sur dev et prod à ce stade.
- **Niveau BLOCK provisoire** pour le jeton dans l'inventaire (voir section 12).
- **Workflow commun futur :** dépôt games/ci-workflows, fichier .gitea/scoped_workflows/games-ci.yaml (chemin standard Gitea). L'écran Scoped Workflows existe dans les paramètres de l'organisation sur Gitea 1.27.0 ; la détection et l'exécution d'un workflow central n'ont pas été testées.
- **Nomenclature locale décidée, non appliquée :** ~/.config/lab et ~/.local/share/lab remplaceront les dossiers gitops-lab. Les termes infrastructure ou platform ne seront utilisés que pour des objets relatifs à l'infrastructure de la plateforme.

### 4. Commits de référence

| Dépôt | Commit | Objet |
|---|---|---|
| infrastructure-devops | 226da7a | refactor(games): serve 2048 image from games/2048 with private pull |
| games/2048 | 0a318110ce16 | ci: publish 2048 images under games/2048 (workflow, set-overlay-digest.sh, fixture, ci/test.sh) |
| infrastructure-devops | e87b627 | chore(dev): deploy 2048 0a31811 (CI), par ci-bot |
| infrastructure-devops | 37a7cf7ff0bf | feat(pra): restore private registry pull secret for games workloads |
| infrastructure-devops | 7bb6230f7db1 | chore(pra): renew workload registrations (généré par le PRA) |

Point de départ : tag v1.3.5 (191ce75).

### 5. Migration des images

Source : gitea.local/gitea_admin/2048. Destination : gitea.local/games/2048. L'ancien package est conservé.

| Tag | Digest de l'index | Usage |
|---|---|---|
| fea0a49 | sha256:7f3e1de6324469d9b7022eab6603b38b4582de10788a0b6605d0dbe5c4d7741f | dev avant migration |
| fb6a4af | sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8 | prod |
| 0a31811 | sha256:76f9ca3203fa945e751a66d161215618415e5d6ff31ea8b800d7c20de51902f3 | dev après la CI du 10 octobre |

Contrôles réalisés : empreinte de chaque manifeste égale à son digest, manifestes enfants lisibles. Les index dev et prod partagent le même manifeste linux/amd64 (bf923dc1…) et diffèrent par leur manifeste d'attestation.

Prérequis outil : Skopeo (paquet Ubuntu, version affichée 1.21.0-dev) installé dans WSL.

### 6. Accès privé en lecture

| Élément | Valeur |
|---|---|
| Équipe | registry-readers (privée), dépôt games/2048, Paquets en lecture, tout le reste en « Aucun accès » |
| Compte | games-puller (visibilité privée, non administrateur), membre de registry-readers uniquement |
| Jeton | games-registry-pull, portée read:package, accès aux organisations et dépôts « Tout » |
| Fichier local | ~/.config/gitops-lab/gitea-games-registry-pull.token, mode 600, hors Git |

Preuves :

- lecture anonyme de games/2048 : « authentication required » ;
- avec le jeton : lecture HTTP 200 ; ouverture d'un envoi (écriture) HTTP 401 ;
- test Kubernetes dans un namespace jetable, dev et prod : avec Secret, pull réussi ; sans Secret, pull refusé.

### 7. Script scripts/ensure-games-pull-secret.sh

Modes :

- **--check** : jeton local conforme (mode 600, 40 caractères hexadécimaux) et lecture du registre ; sans réseau avec EXTERNAL_DEPS_OFFLINE=1.
- **--apply** : crée le namespace s'il est absent (label app.kubernetes.io/part-of=games) puis le Secret ; refuse d'écraser un Secret différent.
- **--verify** : contrôle en lecture seule.

Intégration dans scripts/bootstrap-platform.sh :

- après configure-workload-registry.sh : --apply ;
- dans le prévol, après la sauvegarde Git : --check, avec arrêt avant le menu PRA en cas d'échec ;
- dans --plan : ligne [PLAN] correspondante.

Inventaire : ligne gitea-games-registry-pull-token (BLOCK, type path, mode 600). Prévol : ok=27 warn=0 crit=0.

Tests : codes retour contrôlés (0 création, 0 rejeu, 0 verify, 1 refus d'un Secret différent), aucun résidu temporaire.

### 8. Bascule du socle et de la CI

**Socle (226da7a)** : image de la base, overlays et commentaire Source passés sous games/2048 ; imagePullSecrets games-registry-pull ajouté au Deployment ; digests dev et prod inchangés. Dry-run serveur accepté sur les deux clusters.

**CI games/2048 (0a31811)** : ci.yaml, ci/set-overlay-digest.sh et la fixture de test pointent sur games/2048 ; ajout de ci/test.sh (non utilisé par le workflow à ce jour).

Run ci #12 : tests (4 tests applicatifs, 9 scénarios du script), build-push (tag absent, build, digest 76f9ca32…, index et enfants servis), update-dev-overlay (commit e87b627 par ci-bot, un seul fichier modifié). Dev Synced/Healthy sur le nouveau digest ; prod inchangé sur 12ff0073….

Les workflows historiques ci-dry-run.yaml et runner-smoke-docker.yaml référencent encore gitea_admin/2048.

### 9. PRA de validation

Journal : pra-v1.3.6-20261010-120916.log, fin à 12:16:52 (+02:00), COMMAND_EXIT_CODE="0".

- Prévol : ok=27 warn=0 crit=0 ; contrôle jeton et lecture du registre games conforme.
- Sauvegarde Git games-2048 vers GitHub : fea0a49..0a31811, branches et tags identiques.
- Jeu Gitea figé : 20261010-120931.
- Étape nouvelle : namespace game-2048 et Secret games-registry-pull créés sur dev et prod (apply=OK), sans arrêt du bootstrap.
- Commit PRA : 7bb6230.
- Après PRA : 26 Applications Synced/Healthy, root-app, game-2048-dev et game-2048-prod sur 7bb6230 ; runner gitea-runner-0 2/2 Running.

Confirmé par le PRA :

- Argo CD a repris le namespace game-2048 (annotation tracking-id présente sur dev et prod) ;
- games-puller, l'équipe et son jeton ont survécu à la restauration de Gitea (--check : lecture HTTP 200) ;
- les Pods dev et prod tournent sur 76f9ca32… et 12ff0073…, après téléchargement sur des nœuds neufs depuis un registre qui refuse l'accès anonyme. Les identifiants utilisés ne sont pas visibles directement : c'est une déduction.

### 10. Validation CI après PRA

- Runner enregistré (« Runner registered successfully », « declare successfully »).
- runner-smoke-secrets #11, tentative n°3 : registry, cleanup-registry et gitops-bot réussis. Cela valide après reconstruction le runner, REGISTRY_TOKEN et GITOPS_WRITE_TOKEN.
- ci #12 : vert (37 s). Relance supposée ; numéro de tentative et logs non relus.
- Après relance : aucun nouveau commit dans infrastructure-devops (dernier commit 7bb6230), aucune branche ci-smoke résiduelle, digest du tag 0a31811 inchangé.
- Push mirror GitHub : global=OK, 23 références identiques.

### 11. Écarts et points non confirmés

- **Échec de pull initial après PRA.** Les Pods game-2048 sont créés à 10:14:15 UTC ; ErrImagePull à 10:14:19 (erreur TLS : Traefik présente son certificat par défaut, pas celui de gitea.local) ; le certificat gitea-local est créé à 10:16:50 et Ready à 10:16:51 ; pulls réussis à 10:17:45 (dev) et 10:18:01 (prod). Retard d'environ 3 min 30, résorbé par le kubelet. Cause probable : déploiement de game-2048 avant l'émission du certificat de gitea.local, cohérente avec la chronologie mais non établie. Origine antérieure non vérifiée.
- **Smoke test du run ci non confirmé dans les logs** (voir section 10).
- **Message récurrent** « 'runs-on' key not defined » sur les jobs dépendants, sans effet sur le résultat. Cause non établie.
- **ci/test.sh** n'est pas encore appelé par le workflow.

### 12. Limites connues

- Digest de dev changé (7f3e1de6… vers 76f9ca32…) sans changement de code : un nouveau build produit un autre digest (comportement connu depuis la v1.3.3).
- Niveau BLOCK du jeton : la légende de l'inventaire réserve BLOCK à « PRA irrécupérable sans ». Le jeton est recréable dans Gitea. BLOCK est retenu parce qu'un échec après destruction coûte bien plus qu'un arrêt au prévol. À confirmer ou passer en WARN.
- Le prévol bloque si le registre est injoignable (--check lit le registre). Choix assumé, cohérent avec la sauvegarde Git.
- Namespace game-2048 fixé dans le script (un seul jeu aujourd'hui) ; à généraliser avec games.tsv.
- Pas de TLS valide pour 2048.dev.local et 2048.prod.local (reporté au chantier DNS et PKI).
- L'ancien package gitea_admin/2048 et deux workflows historiques sont conservés jusqu'à décision de nettoyage.
- Le contrôle registry-digests lit le premier couple image et digest de chaque kustomization.yaml (limite déjà connue).

### 13. Chantiers reportés

1. **Renommage des dossiers locaux** vers ~/.config/lab et ~/.local/share/lab : inventaire des occurrences de gitops-lab par famille, vérification du helper Git Gitea, un commit, un PRA. Identifiants dans les clusters (kind-gitops-*, CA) traités à part avec le chantier DNS et PKI.
2. **Journalisation automatique du bootstrap** vers le nouveau dossier de journaux : relance sous script pour le mode complet uniquement, garde contre la relance infinie, umask 077, tests du menu interactif, du code retour et de Ctrl+C.
3. **Mutualisation de la CI games :** ci/test.sh utilisé par le workflow, scripts/games (games.tsv, release-dev.sh, promote-prod.sh), workflow commun games/ci-workflows (scoped workflows à tester), ajout de Snake et Hextris.
4. **Accès privé au socle platform et aux copies GitHub :** identifiants Git d'Argo CD restaurés avant cluster-registration, accès authentifié testé avant de retirer l'accès anonyme, vérification du push mirror et de la sauvegarde Games avec des dépôts GitHub privés. Le Secret Sealed Secrets est installé depuis un chart Helm public, sans dépendance au dépôt privé.
5. **CI de l'organisation platform.**
6. **Nettoyage** de l'ancien package gitea_admin/2048 et des workflows historiques.
7. **Correctif de l'ordre de démarrage** (certificat gitea.local avant le déploiement de game-2048), avec le chantier DNS et PKI.

Orientation Ansible et Terraform : les scripts actuels séparent paramètres, contrôles et actions pour permettre de remplacer certaines implémentations plus tard, sans traduction mécanique de tout le bootstrap.

### 14. Enseignements de la séquence

- Les blocs de commandes sont fournis sous forme de fonctions, sans set -e ni exit dans le shell interactif : un échec ne doit pas fermer la session WSL.
- Un script collé depuis le chat a été corrompu à une ligne (la cause n'a pas été établie) : un contrôle de syntaxe ne suffit pas, les tests exécutent tous les chemins.
- Un nettoyage par trap EXIT référençant une variable locale échouait avec set -u : tester les codes retour, pas seulement l'affichage.
- Un test réussi n'a de valeur que s'il peut échouer : pulls avec et sans Secret, refus d'écriture, refus d'un Secret différent.

### 15. Point de reprise

Contrôles rapides, en lecture seule :

```bash
cd ~/lab/gitea/platform/infrastructure-devops
scripts/ensure-games-pull-secret.sh --check
scripts/ensure-games-pull-secret.sh --verify
scripts/check-external-deps.sh --check
scripts/check-github-mirror.sh --check
kubectl --context kind-gitops-management -n argocd get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
kubectl --context kind-gitops-dev -n game-2048 get deployment game-2048 \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl --context kind-gitops-prod -n game-2048 get deployment game-2048 \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

État attendu :

- infrastructure-devops main : 7bb6230 ou commit ultérieur documenté ;
- games/2048 main : 0a31811 ;
- dev : gitea.local/games/2048@sha256:76f9ca32… ; prod : gitea.local/games/2048@sha256:12ff0073… ;
- 26 Applications Synced/Healthy ; mirror GitHub global=OK (23 références).

### 16. Matrice de validation

| Contrôle | Statut |
|---|---|
| Copie des images dev et prod, digests conservés | VALIDÉ |
| Lecture anonyme refusée | VALIDÉ |
| games-puller : lecture 200, écriture 401 | VALIDÉ |
| Pull Kubernetes avec et sans Secret (dev, prod) | VALIDÉ |
| Bascule du socle sous games/2048 | VALIDÉ |
| CI : tests, build, digest, overlay dev par ci-bot | VALIDÉ |
| Prod inchangé après la CI | VALIDÉ |
| Script du Secret de pull (--check, --apply, --verify) | VALIDÉ |
| Intégration au bootstrap et au prévol | VALIDÉ |
| PRA complet (code retour 0) | VALIDÉ |
| Namespace game-2048 repris par Argo CD | VALIDÉ |
| games-puller et son jeton après restauration | VALIDÉ |
| runner-smoke-secrets après PRA | VALIDÉ |
| Run ci relancé : logs « aucune reconstruction » | NON CONFIRMÉ |
| Pull sans échec TLS initial | NON CONFIRMÉ (3 min 30 de retard) |
| Mirror GitHub | VALIDÉ |
| Mutualisation de la CI games | REPORTÉE |
| Renommage des dossiers locaux | REPORTÉ |
| Journalisation automatique du bootstrap | REPORTÉE |
| Accès privé à platform et aux copies GitHub | REPORTÉ |

### 17. Clôture

La v1.3.6 atteint son objectif réel : les images de 2048 sont servies de façon privée sous games/2048, et ce mécanisme survit à un PRA complet. La mutualisation de la CI, annoncée au départ, est reportée.

Avant le tag : ajouter ce document au dépôt, committer, créer le tag v1.3.6 sur le commit documentaire final, vérifier sa réplication sur GitHub et créer la release Gitea.
