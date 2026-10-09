# GitOps Lab v1.3.3 — CI Gitea, promotion GitOps, PRA et sécurisation des digests

**Date de référence :** 9 octobre 2026
**Statut :** référence détaillée de la version v1.3.3, prête à servir de base à la clôture et aux travaux v1.3.4
**Dépôts concernés :** `gitea_admin/gitops-lab`, `games/2048`
**Plateforme :** WSL + Docker + Kind, cluster management et clusters workload dev/prod

> Ce document distingue les éléments validés, les limites connues et les travaux reportés. Il ne marque pas à lui seul la clôture de la version v1.3.3.

---

## 1. Résumé exécutif

La v1.3.3 a industrialisé la chaîne CI du jeu 2048 sur Gitea Actions, avec un runner partagé au niveau de l’organisation `games`, un registre OCI Gitea, des tests applicatifs, la publication d’une image, la récupération et la vérification de son digest OCI, puis la mise à jour automatique de l’overlay dev dans le dépôt GitOps.

La chaîne validée est la suivante :

```text
commit dans games/2048
  → tests applicatifs
  → tests du script de mise à jour d’overlay
  → détection de l’existence du tag de commit
  → build et push uniquement si le tag est absent
  → lecture du digest OCI
  → vérification de l’index et de ses enfants dans le registre
  → transmission du digest entre jobs
  → mise à jour automatique de l’overlay dev par ci-bot
  → commit GitOps sur gitea_admin/gitops-lab/main
  → réconciliation Argo CD sur dev
  → promotion vers prod conservée manuelle
```

La version a aussi traité un incident important : le relancement de l’ancien workflow a reconstruit le même commit sous le même tag, mais avec un digest OCI différent. L’ancien index est ensuite devenu introuvable dans le registre alors que les overlays le référenceaient encore. La solution retenue empêche désormais la CI de reconstruire lorsqu’un tag de commit existe déjà.

Enfin, le prévol PRA vérifie désormais que chaque digest OCI référencé par les overlays est effectivement servi par le registre. Une anomalie produit un `WARN` non bloquant, conformément à la décision prise de ne pas empêcher le PRA.

---

## 2. Objectifs de la v1.3.3

### 2.1 Objectifs initiaux

- Mettre en place une CI native Gitea pour `games/2048`.
- Déployer un runner Gitea Actions partagé au niveau de l’organisation `games`.
- Construire et publier les images du jeu dans le registre OCI intégré à Gitea.
- Récupérer automatiquement le digest de l’image produite.
- Mettre à jour automatiquement l’overlay dev avec ce digest.
- Conserver une promotion manuelle et explicite vers prod.
- Rendre le runner, ses secrets et la CI restaurables dans le PRA.

### 2.2 Sujets apparus pendant les travaux

- DNS interne `gitea.local` utilisable depuis les jobs et le Docker-in-Docker.
- Gestion des dépendances hors source de vérité.
- Comportement des tags OCI mutables et non-reproductibilité des builds.
- Protection contre la disparition d’un digest référencé.
- Idempotence d’un relancement de CI.
- Contrôle de prévol des digests OCI.
- Limites du secours GitHub actuel pour les dépôts applicatifs de l’organisation `games`.

---

## 3. Architecture retenue

### 3.1 Dépôts

| Dépôt | Rôle |
|---|---|
| `gitea_admin/gitops-lab` | Source de vérité GitOps de la plateforme et des environnements |
| `games/2048` | Code source, Dockerfile, tests, scripts CI et workflows Gitea Actions du jeu |
| GitHub `gitops-lab` | Secours Git du dépôt GitOps via push mirror Gitea |

Les futurs jeux `snake` et `hextris` sont prévus comme dépôts supplémentaires dans l’organisation Gitea `games`.

### 3.2 Environnements

- `kind-gitops-management` : Gitea, Argo CD, Traefik, cert-manager, Sealed Secrets, runner Gitea Actions.
- `kind-gitops-dev` : déploiement dev du jeu 2048.
- `kind-gitops-prod` : déploiement prod du jeu 2048.

### 3.3 Stratégie de promotion

- La CI met automatiquement à jour **uniquement dev**.
- L’overlay dev fixe l’image par digest OCI.
- Prod ne suit pas automatiquement dev.
- La promotion prod reste une modification GitOps distincte et manuelle, afin de promouvoir exactement le digest validé en dev.

Cette stratégie évite des branches longues `dev` et `prod`. Les environnements sont portés par les overlays GitOps, tandis que le même artefact OCI est promu par digest.

---

## 4. Runner Gitea Actions

### 4.1 Positionnement

Le runner est partagé à l’échelle de l’organisation `games`. Il expose les labels :

```text
lab-node22
lab-docker
```

Il s’exécute dans le cluster management et utilise un sidecar Docker-in-Docker pour les builds conteneurisés.

### 4.2 Persistance et PRA

Le runner dispose d’un PVC :

```text
data-gitea-runner-0
```

Après un PRA, le PVC est nouveau et le runner se réenregistre automatiquement. Le journal validé après reconstruction contient notamment :

```text
Runner registered successfully.
Docker is ready
runner: lab-games, with version: v3.5.0, with labels: [lab-node22 lab-docker], declare successfully
```

### 4.3 Secrets liés au runner et à la CI

Les fichiers locaux hors Git suivants sont contrôlés en mode `600` :

```text
~/.config/gitops-lab/gitea-registry-publish.token
~/.config/gitops-lab/gitea-ci-gitops-write.token
~/.config/gitops-lab/gitea-runner-registration.token
```

Rôles :

- `gitea-registry-publish.token` : publication et lecture authentifiée du registre OCI.
- `gitea-ci-gitops-write.token` : écriture du compte `ci-bot` sur `gitea_admin/gitops-lab`.
- `gitea-runner-registration.token` : réenregistrement du runner de l’organisation `games`.

Côté Gitea Actions, les secrets d’organisation utilisés sont notamment :

```text
REGISTRY_TOKEN
GITOPS_WRITE_TOKEN
```

Leur restauration avec Gitea a été validée indirectement après PRA par une publication authentifiée dans le registre et par un push de `ci-bot` vers `gitops-lab/main`.

---

## 5. DNS et accès au registre depuis la CI

Le runner et le Docker imbriqué doivent résoudre `gitea.local` vers l’entrée de la plateforme.

Le bootstrap applique sur le cluster management une réécriture CoreDNS :

```text
gitea.local → traefik.traefik.svc.cluster.local
```

Les nœuds workload reçoivent aussi la CA et la configuration containerd nécessaires pour tirer des images depuis `gitea.local`.

Après PRA, les validations ont confirmé :

- la restauration de la réécriture CoreDNS ;
- la résolution de `gitea.local` depuis les workloads ;
- le pull des images depuis le registre restauré ;
- le fonctionnement de la CI depuis le runner recréé.

---

## 6. Workflow CI final de `games/2048`

Le workflow contient trois jobs :

```text
tests
build-push
update-dev-overlay
```

### 6.1 Job `tests`

Le job :

1. clone `games/2048` par l’URL interne Gitea ;
2. vérifie que le `HEAD` cloné correspond à `gitea.sha` ;
3. exécute les tests applicatifs Node ;
4. exécute les tests du script `ci/set-overlay-digest.sh`.

Résultats validés :

```text
4 tests applicatifs réussis
9 scénarios de test du script réussis
[RESULT] OK
```

Les tests du script couvrent notamment :

- mise à jour nominale ;
- rejeu identique ;
- refus d’un digest invalide ;
- refus d’un commit invalide ;
- refus de plusieurs lignes `digest` ;
- refus d’une ligne `digest` absente ;
- refus d’une ligne image absente ;
- refus d’un lien symbolique ;
- comportement si la ligne `Source` est absente.

### 6.2 Job `build-push`

Le tag OCI correspond au SHA court du commit applicatif :

```text
TAG = gitea.sha[0:7]
```

Le job interroge d’abord le registre :

- `HTTP 200` : le tag existe, aucune reconstruction ;
- `HTTP 404` : le tag est absent, build et push ;
- autre code : arrêt, état indéterminé.

Après publication ou réutilisation, le job :

1. lit le manifeste du tag ;
2. récupère `docker-content-digest` ;
3. vérifie la forme `sha256:<64 caractères hexadécimaux>` ;
4. vérifie que l’index répond `HTTP 200` ;
5. extrait chaque digest enfant de l’index ;
6. vérifie que chaque enfant répond `HTTP 200` ;
7. publie le digest dans `GITHUB_OUTPUT` pour le job suivant.

### 6.3 Job `update-dev-overlay`

Le job :

1. reçoit `needs.build-push.outputs.digest` ;
2. clone `games/2048` avec le jeton de lecture ;
3. clone `gitea_admin/gitops-lab` avec `GITOPS_WRITE_TOKEN` ;
4. exécute `ci/set-overlay-digest.sh` sur l’overlay dev ;
5. vérifie que le seul fichier modifié est :

```text
applications/games/2048/overlays/dev/kustomization.yaml
```

6. commite avec l’identité :

```text
ci-bot <ci-bot@gitea.local>
```

7. pousse sur `gitops-lab/main` ;
8. en cas de refus du push, recharge `main` et retente, jusqu’à trois essais.

Message de commit :

```text
chore(dev): deploy 2048 <sha-court> (CI)
```

Prod est explicitement exclu de cette automatisation.

---

## 7. Incident du tag mutable et du digest disparu

### 7.1 Situation initiale

Le commit applicatif `a6a3d34` avait produit l’index :

```text
sha256:7391ef3d981ab4b78193156a1671464f2938dccb2c923de907711037038d608d
```

Les overlays dev et prod avaient été promus sur ce digest, et un PRA avait réussi en le retéléchargeant depuis le registre restauré.

### 7.2 Relancement destructif de l’ancien workflow

Une ancienne exécution du workflow `ci` a été relancée alors que le workflow reconstruisait systématiquement l’image.

Le même commit `a6a3d34`, sous le même tag, a produit un nouvel index :

```text
sha256:f39c5eb1b8d7cc0a2f727621185714b732e6fb9988d6254b39fe689ef17289ef
```

Enfants validés :

```text
linux/amd64 : sha256:27fed56e38c39635ba2155b66f2f5876669fd6a3bce608d9f3e19e35ef979021
attestation  : sha256:b9fa64c17e50376b9dc0584c1eedb4f67bc467a8c04dc8196d99549f72926e7a
```

L’ancien index `7391ef3d…` a ensuite répondu `HTTP 404`. Dev et prod continuaient de fonctionner uniquement grâce au cache containerd, alors que les overlays pointaient vers un digest absent du registre.

### 7.3 Cause exacte non prouvée

Deux sujets ont été distingués :

1. **Non-reproductibilité du build** : deux builds du même commit peuvent produire des digests différents, notamment à cause des métadonnées et attestations de build.
2. **Disparition de l’ancien index dans Gitea** : le comportement exact n’a pas été établi de manière définitive.

Le test de reproductibilité détaillé envisagé n’a pas été exécuté. Il est reporté.

### 7.4 Remédiation immédiate

Les overlays ont été corrigés séparément :

- commit dev : `86bc4d9` ;
- commit prod : `8449329`.

Les deux environnements ont été alignés sur `f39c5eb1…`, puis validés `Synced/Healthy` avec des pods `Running`.

---

## 8. Comportement actuel lors d’un relancement de CI

### 8.1 Nouveau commit

```text
nouveau SHA court
  → tag absent
  → build
  → push
  → vérification index + enfants
  → mise à jour automatique de dev
```

Exemple validé :

```text
commit applicatif : 5f8fef0
tag OCI           : 5f8fef0
index OCI         : sha256:b31dfa3cbb77e74e0999e8013787e7adaa4ab566ac19e3b60bd1afeb5016035e
commit GitOps     : 330f587
```

Dev a été redéployé sur `b31dfa3c…`. Prod est resté sur `f39c5eb1…`.

### 8.2 Relancement du même commit

Le relancement validé produit :

```text
[INFO] le tag 5f8fef0 existe déjà : aucune reconstruction
[OK] tag 5f8fef0 -> index sha256:b31dfa3c..., index et enfants servis
[INFO] overlay dev déjà à jour ; rien à commiter
```

Garanties validées :

- aucun `docker build` ;
- aucun `docker push` ;
- digest du tag inchangé ;
- aucun nouveau commit GitOps ;
- aucun redéploiement dev ;
- pod dev conservé.

### 8.3 Nature de l’immutabilité

Le tag reste techniquement mutable dans Gitea. La CI applique une **immutabilité par convention** : elle refuse de reconstruire si le tag existe déjà.

Cela ne protège pas contre :

- un push manuel sur le même tag ;
- un autre workflow utilisant le même jeton ;
- la suppression puis recréation volontaire du tag ;
- deux exécutions concurrentes atteignant la fenêtre entre test et push.

La protection opérationnelle repose donc sur :

- un tag dérivé du commit ;
- l’évitement de la reconstruction ;
- le déploiement par digest ;
- la vérification prévol des digests référencés.

---

## 9. Options d’amélioration reportées

Les options suivantes ont été discutées, mais volontairement écartées de la v1.3.3 afin de garder une CI simple.

### 9.1 Build reproductible

Pistes :

- `SOURCE_DATE_EPOCH` ;
- maîtrise des horodatages et métadonnées ;
- dépendances et image de base épinglées ;
- étude des attestations BuildKit ;
- double build comparatif sans push.

Objectif potentiel : déterminer si la variation provient des couches de l’image, de l’attestation ou des deux.

### 9.2 Reconstruction explicite

Option envisagée : un `workflow_dispatch` manuel avec motif obligatoire, produisant un nouveau tag tel que :

```text
<sha-court>-r2
```

Cette option ne devrait pas réécrire un tag existant.

### 9.3 Tag mobile

Option envisagée : maintenir un tag mobile `dev` ou `latest` en complément du tag immuable par commit.

Avant adoption, il faudrait tester le comportement Gitea lorsqu’un tag mobile change alors que l’index possède aussi un tag de commit.

### 9.4 Politique d’immutabilité côté registre

Aucune politique native d’immutabilité des tags n’a été mise en œuvre dans Gitea. Si cette exigence devient importante, étudier :

- un registre disposant d’une politique d’immutabilité ;
- des permissions de jetons plus fines ;
- un contrôle externe plus strict.

### 9.5 Concurrence des workflows

Le support de `concurrency` n’a pas été retenu dans ce lot. À étudier si plusieurs pushes rapides ou plusieurs jeux utilisent simultanément le runner et modifient le dépôt GitOps.

### 9.6 Généralisation à l’organisation `games`

Le workflow actuel contient encore des valeurs spécifiques à `2048` :

- chemin de dépôt ;
- chemin d’overlay ;
- nom de package OCI ;
- message de commit.

Pour Snake et Hextris, plusieurs options sont possibles :

1. recopier un workflow par dépôt, avec paramètres propres ;
2. créer une action composite commune ;
3. créer un workflow réutilisable commun ;
4. versionner un inventaire des applications et de leurs overlays ;
5. fournir un script générique recevant propriétaire, dépôt, package et overlay.

La décision est reportée afin d’observer d’abord l’usage réel avec un deuxième jeu.

---

## 10. Contrôle de prévol des digests OCI

### 10.1 Besoin

L’incident a montré qu’un overlay peut référencer un digest devenu absent du registre alors que les pods continuent temporairement de tourner grâce au cache.

### 10.2 Implémentation

Le type de contrôle suivant a été ajouté à `scripts/check-external-deps.sh` :

```text
registry-digests
```

Entrée correspondante dans `scripts/external-deps.tsv` :

```text
gitops-registry-digests
```

Le contrôle :

1. parcourt les `kustomization.yaml` sous `applications/` ;
2. extrait une image `gitea.local/...` et son digest ;
3. interroge le manifeste par digest ;
4. exige `HTTP 200` ;
5. compare l’en-tête `docker-content-digest` au digest demandé.

### 10.3 Niveau et codes retour

- Digest disponible : `OK`.
- Digest absent ou incohérent : `WARN`.
- Code global : `2` en présence d’un avertissement.
- Le bootstrap accepte explicitement les codes `0` et `2`.
- Le PRA continue donc malgré le `WARN`.
- En mode `--offline`, le contrôle réseau est ignoré.

### 10.4 Tests validés

#### Nominal

```text
[OK] 2 digest(s) OCI référencé(s) servi(s) dans applications
[RESULT] global=OK ok=25 warn=0 crit=0
```

#### Hors ligne

```text
[RESULT] global=OK ok=17 warn=0 crit=0
```

#### Digest absent simulé

```text
[WARN] 1/1 digest(s) absent(s) ou incohérent(s)
[RESULT] global=WARN ok=24 warn=1 crit=0
code retour : 2
```

### 10.5 Commit

```text
03e94ba feat(preflight): warn when a referenced registry digest is missing
```

Le push mirror GitHub de `gitops-lab` a ensuite été contrôlé : branches et tags identiques, `global=OK`.

---

## 11. PRA validé pendant la v1.3.3

Un PRA complet a été rejoué après les modifications CI et la correction des digests.

### 11.1 Avant destruction

- prévol global réussi ;
- dépôt local aligné avec Gitea ;
- push mirror GitHub conforme ;
- dépendances hors source de vérité conformes ;
- DNS management contrôlé ;
- sauvegarde fraîche Gitea créée : `20261009-203129`.

### 11.2 Reconstruction

- trois clusters Kind supprimés puis recréés ;
- Gitea restauré avant activation de la Root App ;
- enregistrements workloads renouvelés ;
- commit PRA publié : `3f1e56d` ;
- `cluster-registration` synchronisée ;
- Root App activée ;
- 26 Applications `Synced/Healthy` ;
- runner restauré et réenregistré ;
- dev et prod restaurés sur `f39c5eb1…` ;
- index, enfants et tag CI restaurés dans le registre ;
- mirror GitHub `gitops-lab` conforme.

### 11.3 CI après PRA

Le workflow `63b2f64` a été relancé après PRA :

- tests réussis ;
- tag existant détecté ;
- aucune reconstruction ;
- index et enfants servis ;
- digest transmis entre jobs ;
- runner et secrets CI opérationnels après restauration.

---

## 12. Commits structurants de la séquence

### Dépôt `gitops-lab`

| Commit | Objet |
|---|---|
| `86bc4d9` | Correction de l’overlay dev vers l’index republié |
| `8449329` | Correction de l’overlay prod vers l’index republié |
| `3f1e56d` | Renouvellement des enregistrements workloads pendant le PRA |
| `330f587` | Mise à jour automatique de l’overlay dev par `ci-bot` |
| `03e94ba` | Avertissement de prévol si un digest référencé manque |

### Dépôt `games/2048`

| Commit | Objet |
|---|---|
| `63b2f64` | Ne pas reconstruire si le tag existe et vérifier le digest servi |
| `5f8fef0` | Écrire automatiquement le digest vérifié dans l’overlay dev |

---

## 13. État final observé

### Dev

```text
image : gitea.local/gitea_admin/2048@sha256:b31dfa3cbb77e74e0999e8013787e7adaa4ab566ac19e3b60bd1afeb5016035e
Argo CD : Synced/Healthy
```

### Prod

```text
image : gitea.local/gitea_admin/2048@sha256:f39c5eb1b8d7cc0a2f727621185714b732e6fb9988d6254b39fe689ef17289ef
```

La divergence est volontaire : dev suit le dernier build CI, prod reste sur le digest précédemment promu.

### GitOps

```text
main local = gitea/main
push mirror GitHub = conforme
prévol complet = code 0
```

---

## 14. Secours GitHub : situation actuelle

### 14.1 Ce qui est protégé

Le push mirror natif Gitea vers GitHub est configuré sur le seul dépôt :

```text
gitea_admin/gitops-lab
```

Le contrôle actuel vérifie :

- le PAT GitHub ;
- l’existence du push mirror ;
- `sync_on_commit` ;
- l’absence d’erreur ;
- l’identité des branches et tags.

### 14.2 Ce qui n’est pas protégé par ce mirror

Le push mirror n’est pas défini au niveau de l’instance ou de l’organisation. Il ne protège donc pas automatiquement :

```text
games/2048
futur games/snake
futur games/hextris
```

En cas de perte simultanée :

- de Gitea ;
- des sauvegardes Gitea ;
- des clones locaux ;

le dépôt `games/2048` ne serait pas récupérable depuis le GitHub actuel.

Même avec le code source sauvegardé, les images OCI ne sont pas sauvegardées par GitHub. Elles resteraient à reconstruire, avec un nouveau digest potentiel.

---

## 15. Plan v1.3.4 probable : sauvegarde GitHub des dépôts `games` avant PRA

### 15.1 Décision d’orientation

La configuration d’un push mirror permanent pour chaque dépôt applicatif a été jugée disproportionnée pour le lab.

L’orientation retenue pour étude est une sauvegarde groupée, déclenchée par le bootstrap PRA **avant toute destruction des clusters**.

### 15.2 Cinématique cible

```text
prévol PRA
  → lister les dépôts de l’organisation Gitea games
  → vérifier les prérequis et le PAT GitHub
  → pour chaque dépôt games :
       vérifier que le dépôt GitHub cible existe
       cloner le dépôt Gitea en mode mirror/bare
       pousser toutes les références vers GitHub
       comparer les références source et cible
  → si tous les dépôts sont conformes :
       sauvegarde fraîche complète de Gitea
       destruction des clusters
  → sinon :
       STOP avant destruction
```

### 15.3 Correspondance proposée

```text
Gitea games/2048    → GitHub <compte-ou-organisation>/2048
Gitea games/snake   → GitHub <compte-ou-organisation>/snake
Gitea games/hextris → GitHub <compte-ou-organisation>/hextris
```

### 15.4 Découverte des dépôts

La première option envisagée est de lister dynamiquement les dépôts de l’organisation `games` via l’API Gitea.

Alternative plus prudente : maintenir un inventaire versionné des dépôts obligatoires. Cette approche évite qu’un dépôt temporaire soit sauvegardé sans décision explicite.

Décision à prendre en v1.3.4 :

- découverte automatique complète ;
- inventaire explicite ;
- ou découverte avec liste d’exclusion.

### 15.5 Dépôts GitHub cibles

Les dépôts GitHub doivent probablement être créés au préalable. La création automatique par API n’est pas retenue pour le premier incrément afin de limiter les permissions du PAT et d’éviter la création accidentelle de dépôts.

### 15.6 Type de push

Le mécanisme envisagé est :

```text
git clone --mirror <gitea-repo>
git push --mirror <github-repo>
```

Conséquence : les références GitHub absentes de Gitea peuvent être supprimées. Les dépôts GitHub doivent être considérés comme des sauvegardes pilotées par Gitea, sans commits directs.

Avant implémentation, préciser si toutes les références doivent être dupliquées ou seulement :

```text
refs/heads/*
refs/tags/*
```

Une synchronisation limitée aux branches et tags est moins intrusive ; un vrai mirror est plus exhaustif.

### 15.7 Authentification cible

#### Lecture Gitea

Réutilisation envisagée :

```text
~/.config/gitops-lab/gitea-git-token
```

#### Écriture GitHub

Créer un PAT dédié, stocké localement, par exemple :

```text
~/.config/gitops-lab/github-games-backup.token
```

Exigences :

- mode `600` ;
- permissions limitées aux dépôts GitHub de sauvegarde ;
- jamais affiché ;
- inventorié dans `scripts/external-deps.tsv` ;
- date d’expiration contrôlée ;
- copie conservée dans le gestionnaire de mots de passe.

Aucun Secret ou SealedSecret Kubernetes n’est nécessaire : la sauvegarde est lancée depuis WSL avant la destruction.

### 15.8 Politique d’échec

Recommandation :

```text
échec de sauvegarde d’un dépôt games
  → STOP avant destruction
```

Le but du mécanisme étant précisément de disposer d’une copie fraîche lorsque Gitea va être détruit, un simple `WARN` annulerait sa valeur de sécurité.

Un contournement explicite pourrait être ajouté plus tard, mais ne doit pas être implicite.

### 15.9 Contrôles à implémenter

Pour chaque dépôt :

- dépôt Gitea accessible ;
- dépôt GitHub cible existant ;
- authentification GitHub valide ;
- push réussi ;
- branches identiques ;
- tags identiques ;
- aucun secret affiché ;
- nettoyage du clone temporaire ;
- synthèse globale lisible.

### 15.10 Intégration au bootstrap

Point d’insertion recommandé :

```text
après les prévols non destructifs
avant la sauvegarde fraîche Gitea
avant le menu ou, au minimum, avant la destruction effective
```

Le choix exact doit préserver les principes existants :

- pas de modification de l’arbre Git principal ;
- échec avant destruction ;
- journal détaillé ;
- dry-run ou mode de contrôle séparé ;
- nettoyage garanti des répertoires temporaires.

### 15.11 Tests attendus en v1.3.4

1. Cas nominal sur `games/2048`.
2. Dépôt GitHub cible absent.
3. PAT absent ou mode différent de `600`.
4. PAT expiré ou permissions insuffisantes.
5. Branche manquante sur GitHub avant synchronisation.
6. Tag manquant sur GitHub avant synchronisation.
7. Divergence créée uniquement sur GitHub.
8. Dépôt Gitea privé.
9. Deux dépôts dans `games`.
10. Simulation d’échec sur le second dépôt : aucune destruction.
11. PRA complet avec sauvegarde GitHub juste avant destruction.
12. Reprise à partir de GitHub en l’absence de Gitea, au moins sous forme de procédure documentée.

### 15.12 Limites du futur mécanisme

La sauvegarde Git vers GitHub ne couvre pas :

- les images OCI ;
- les secrets Gitea Actions ;
- les paramètres des organisations ;
- les comptes et jetons Gitea ;
- les exécutions CI ;
- les runners ;
- les issues, pull requests et métadonnées Gitea.

La sauvegarde complète Gitea reste la restauration principale. GitHub devient un recours pour les sources Git.

---

## 16. Push Gitea local non interactif : sujet ouvert

Les commandes manuelles :

```text
git push gitea main
```

demandent aujourd’hui un identifiant et un mot de passe/jeton.

Le bootstrap utilise déjà `~/.config/gitops-lab/gitea-git-token` de manière non interactive via `gitea-publish.sh`.

Piste recommandée : un credential helper Git local et limité à `gitea.local`, lisant ce fichier en mode `600`.

Il n’est pas nécessaire d’ajouter un SealedSecret dans Kubernetes, car le push est exécuté depuis WSL.

Ce sujet n’a pas encore été implémenté. Il peut être traité en v1.3.4 ou comme amélioration séparée.

---

## 17. Limites connues

- Le message Gitea Actions suivant apparaît sur les jobs dépendants, sans empêcher leur succès :

```text
'runs-on' key not defined in ci/<job-précédent>
```

Cause non établie.

- Le contrôle `registry-digests` lit actuellement le premier couple image Gitea + digest de chaque `kustomization.yaml`. Une évolution sera nécessaire si un même fichier référence plusieurs images Gitea.
- La CI est spécifique à `2048`.
- Prod reste manuel par choix.
- L’immutabilité des tags n’est pas imposée par le registre.
- Les images OCI ne sont pas protégées par le mirror GitHub.
- Le test approfondi de reproductibilité n’a pas été exécuté.
- La gestion explicite de la concurrence n’a pas été mise en œuvre.

---

## 18. Décisions à conserver

1. Gitea reste la source de vérité principale.
2. GitHub reste un secours, pas un second point d’écriture.
3. Les déploiements utilisent des digests OCI, pas des tags.
4. La CI met à jour dev uniquement.
5. La promotion prod reste explicite et manuelle.
6. Un tag de commit existant n’est pas reconstruit.
7. L’index et ses enfants doivent être servis avant toute écriture d’overlay.
8. Un digest référencé absent produit un `WARN` de prévol, mais ne bloque pas le PRA.
9. Les secrets locaux restent hors Git et sont inventoriés.
10. Les changements PRA doivent rester vérifiables et reproductibles.

---

## 19. Proposition de périmètre pour v1.3.4

### Priorité 1

- Écrire le script de sauvegarde GitHub de l’organisation `games`.
- Définir découverte automatique ou inventaire explicite.
- Créer un PAT GitHub dédié et contrôlé.
- Intégrer la sauvegarde au bootstrap avant destruction.
- Tester l’échec bloquant.

### Priorité 2

- Documenter la reprise d’un dépôt `games` depuis GitHub.
- Généraliser le contrôle à plusieurs dépôts.
- Ajouter Snake comme deuxième cas réel et valider l’extensibilité.

### Priorité 3

- Généraliser le workflow CI commun aux jeux.
- Étudier un helper Git local pour les pushes Gitea non interactifs.
- Étudier la concurrence des workflows.

### Hors périmètre immédiat

- Registre OCI secondaire.
- Reproductibilité parfaite des builds.
- Politique d’immutabilité forte côté registre.
- Sauvegarde des issues, pull requests et exécutions CI.

---

## 20. Checklist de clôture v1.3.3

- [x] Runner Gitea Actions partagé déployé.
- [x] Runner restauré et réenregistré après PRA.
- [x] DNS `gitea.local` utilisable depuis la CI.
- [x] Tests applicatifs exécutés par la CI.
- [x] Build et push OCI fonctionnels.
- [x] Digest transmis entre jobs.
- [x] Index et enfants vérifiés.
- [x] Overlay dev mis à jour automatiquement.
- [x] Prod non modifié par la CI.
- [x] Relancement idempotent validé.
- [x] PRA complet validé.
- [x] Digests restaurés validés.
- [x] Contrôle prévol des digests ajouté.
- [x] Comportements nominal, offline et WARN testés.
- [x] Push mirror `gitops-lab` vérifié.
- [ ] Intégrer ou remplacer les trois documents de travail non suivis.
- [ ] Commit final documentaire.
- [ ] Décider formellement la clôture.
- [ ] Créer le tag `v1.3.3` et la release Gitea.
- [ ] Vérifier la réplication du tag sur GitHub.

---

## 21. Fichiers de travail à consolider

Au moment de la rédaction, trois documents de travail étaient présents hors suivi Git :

```text
docs/gitops-lab-v1.3.3-annexe-schemas-flux-2026-10-08.md
docs/gitops-lab-v1.3.3-en-cours-2026-10-08.md
docs/gitops-lab-v1.3.3-note-ci-reproductibilite-2026-10-09.md
```

Ils doivent être relus puis :

- fusionnés dans ce document ;
- conservés comme annexes utiles ;
- ou supprimés s’ils deviennent redondants.

Aucun de ces fichiers ne doit être ajouté au commit final sans cette décision.

---

## 22. Conclusion

La v1.3.3 transforme le lab en une chaîne CI/GitOps fonctionnelle et restaurable : le code est testé, construit et publié dans Gitea, le digest réellement servi est contrôlé, dev est mis à jour automatiquement et prod reste une promotion explicite.

L’incident du tag mutable a conduit à une amélioration structurante : un relancement du même commit ne reconstruit plus l’image, ne réécrit plus le tag et ne génère aucun changement GitOps. Le prévol détecte aussi désormais les digests devenus indisponibles.

La prochaine priorité n’est plus le fonctionnement de la CI 2048, qui est validé, mais l’extension du dispositif à l’organisation `games` et la sécurisation des sources applicatives avant chaque PRA. La v1.3.4 pourra ainsi consolider Snake, Hextris et les futurs dépôts sans multiplier les configurations manuelles de push mirror.
