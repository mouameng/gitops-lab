# GitOps Lab — Clôture v1.3.4

**Date de clôture fonctionnelle :** 10 octobre 2026
**Statut :** v1.3.4 fonctionnellement validée
**Périmètre principal :** sauvegarde Git fraîche des dépôts applicatifs avant PRA, restauration complète, puis validation de la CI/CD Gitea Actions jusqu’à `workload-prod`.

> Ce document constitue la référence de clôture de la v1.3.4. Il consolide les décisions, les changements, les preuves de validation, les limites connues et le plan de reprise. Les documents historiques des versions précédentes restent inchangés.

---

## 1. Synthèse exécutive

La v1.3.4 complète le dispositif PRA du lab en ajoutant une sauvegarde fraîche et autoritaire des dépôts applicatifs Gitea vers GitHub avant toute destruction des clusters.

Le premier dépôt couvert est :

```text
Gitea  : games/2048
GitHub : mouameng/games-2048
```

Le PRA vérifie désormais que les dépôts Gitea concernés sont inventoriés, que leurs destinations GitHub existent et sont accessibles, puis synchronise leurs branches et tags avant de créer la sauvegarde fraîche complète de Gitea.

L’ordre sécurisé validé est :

```text
Prévol général
  -> découverte des dépôts Gitea
  -> contrôle des destinations GitHub
  -> choix explicite du PRA
  -> synchronisation Git fraîche vers GitHub
  -> sauvegarde fraîche complète de Gitea
  -> validation et gel du jeu Gitea
  -> destruction des clusters
  -> reconstruction
  -> restauration Gitea
  -> réactivation GitOps
  -> validation applicative
```

La version a été validée par un PRA complet terminé avec le code retour `0`, suivi d’une exécution réelle de la chaîne CI/CD de `2048` :

```text
commit applicatif
  -> tests
  -> build OCI
  -> publication dans le registre Gitea
  -> validation du digest
  -> mise à jour automatique de l’overlay dev
  -> déploiement Argo CD sur workload-dev
  -> validation visuelle
  -> promotion manuelle du même digest
  -> déploiement Argo CD sur workload-prod
  -> validation visuelle
```

---

## 2. Objectifs de la v1.3.4

### 2.1 Objectif principal

Garantir qu’un dépôt applicatif hébergé dans Gitea dispose d’une copie GitHub fraîche et contrôlée avant la destruction du cluster management lors d’un PRA.

### 2.2 Objectifs complémentaires

- Détecter les dépôts Gitea non inventoriés.
- Bloquer le PRA si un dépôt obligatoire est absent ou si sa destination GitHub est inaccessible.
- Ne sauvegarder que les branches et tags, sans recopier toutes les références techniques.
- Considérer Gitea comme source de vérité et GitHub comme copie de secours autoritaire.
- Vérifier l’identité exacte des références après chaque synchronisation.
- Intégrer la sauvegarde Git avant la sauvegarde fraîche complète de Gitea.
- Valider que la CI Gitea Actions reste fonctionnelle après restauration du PRA.
- Valider le déploiement progressif dev puis prod avec une image OCI immuable référencée par digest.

---

## 3. Architecture retenue

### 3.1 Rôles des dépôts

```text
games/2048
  Source applicative
  Tests
  Dockerfile
  Workflow Gitea Actions
  Script de mise à jour du digest


gitea_admin/gitops-lab
  État désiré GitOps
  Overlays dev et prod
  Scripts PRA
  Inventaire des dépôts à sauvegarder
  Inventaire des dépendances externes


mouameng/games-2048
  Copie GitHub de secours de games/2048
```

### 3.2 Convention de nommage GitHub

GitHub ne permet pas un chemin à trois niveaux tel que :

```text
mouameng/games/2048
```

La convention retenue est donc :

```text
<organisation-gitea>/<dépôt>
        ->
<compte-github>/<organisation-gitea>-<dépôt>
```

Exemple validé :

```text
games/2048 -> mouameng/games-2048
```

### 3.3 Politique de synchronisation

La politique retenue est `heads-tags` :

```text
refs/heads/*
refs/tags/*
```

La synchronisation utilise un push forcé avec purge des références absentes de Gitea :

```text
+refs/heads/*:refs/heads/*
+refs/tags/*:refs/tags/*
```

Conséquence assumée : une branche ou un tag créé uniquement sur GitHub est supprimé au prochain `--sync`.

Gitea reste la source de vérité. GitHub n’est pas un second point d’écriture.

---

## 4. Fichiers introduits ou modifiés

### 4.1 Nouveau manifeste des sauvegardes Git

Fichier :

```text
scripts/git-backup-repositories.tsv
```

Entrée initiale :

```text
games-2048	REQUIRED	games	2048	mouameng	games-2048	heads-tags
```

Les colonnes représentent :

```text
id
statut
propriétaire Gitea
dépôt Gitea
propriétaire GitHub
dépôt GitHub
politique de références
```

### 4.2 Nouveau script de sauvegarde Git

Fichier :

```text
scripts/backup-git-repositories.sh
```

Modes disponibles :

```text
--validate
--preflight
--sync
--help
```

#### `--validate`

- Vérifie la structure TSV.
- Refuse les doublons d’identifiant, de source et de destination.
- Refuse les statuts ou politiques inconnus.
- Fonctionne sans accès réseau.

#### `--preflight`

- Valide le manifeste.
- Découvre les dépôts présents dans les organisations Gitea inventoriées.
- Bloque un dépôt Gitea découvert mais non inventorié.
- Bloque un dépôt `REQUIRED` absent.
- Contrôle l’accessibilité de chaque destination GitHub.
- Utilise un jeton Gitea de découverte en lecture seule.

#### `--sync`

- Clone chaque dépôt source en bare dans un répertoire temporaire.
- Pousse uniquement les branches et tags vers GitHub.
- Purge les branches et tags absents de Gitea.
- Relit toutes les références des deux côtés.
- Compare exactement les sorties triées.
- Nettoie le répertoire temporaire en fin normale et lors de la sortie du shell.

### 4.3 Inventaire des dépendances externes

Fichier modifié :

```text
scripts/external-deps.tsv
```

Nouvelle dépendance bloquante :

```text
gitea-repository-discovery-token
BLOCK
path
~/.config/gitops-lab/gitea-repository-discovery.token
600
```

Ce jeton possède la portée Gitea :

```text
read:organization
```

Il sert uniquement à découvrir les dépôts d’une organisation lors du prévol.

La description de `gitea-git-token` a également été corrigée : ce jeton reste dédié aux opérations Git depuis WSL et n’est plus présenté comme jeton de découverte API.

### 4.4 Assistant d’identification Git pour Gitea

Un assistant d’identification Git local a été installé pour les accès HTTPS à `gitea.local`. Son objectif est d’éviter la saisie répétée du login et du mot de passe ou jeton lors des opérations courantes :

```text
git fetch
git pull
git push
git ls-remote
```

Le secret utilisé par cet assistant reste hors du dépôt Git. Il ne doit être ni intégré aux URL des remotes, ni écrit dans les scripts versionnés, ni affiché dans les journaux. Le jeton Git Gitea fait partie des dépendances locales contrôlées par le lab.

Le comportement non interactif est volontairement testé avec :

```bash
GIT_TERMINAL_PROMPT=0 git fetch gitea main
GIT_TERMINAL_PROMPT=0 git push gitea main
```

Avec `GIT_TERMINAL_PROMPT=0`, une absence ou une mauvaise configuration des identifiants provoque un échec immédiat au lieu d’ouvrir une invite interactive.

Validation réelle pendant le chantier : le commit `d4f2e16` a été poussé vers `gitea/main` sans demande d’identification, puis les SHA local, branche de suivi et branche distante ont été comparés et trouvés identiques. Le même mécanisme a ensuite permis les opérations Git non interactives des prévols et de la clôture.

Distinction importante :

```text
Assistant Git du poste   -> opérations HTTPS effectuées depuis WSL
GITEA_TOKEN              -> lecture du dépôt source dans les jobs Gitea Actions
GITOPS_WRITE_TOKEN       -> écriture de ci-bot dans gitops-lab depuis la CI
REGISTRY_TOKEN           -> publication et lecture contrôlée du registre OCI
```

L’assistant du poste ne remplace donc pas les secrets de l’organisation `games` utilisés par les workflows.

### 4.5 Intégration au bootstrap PRA

Fichier modifié :

```text
scripts/bootstrap-platform.sh
```

Deux intégrations distinctes ont été ajoutées.

#### Prévol avant le menu PRA

```text
backup-git-repositories.sh --preflight
```

Ce contrôle intervient après les dépendances externes et avant les gardes finales précédant le menu PRA.

#### Chemin opérationnel après confirmation du PRA

Lorsque le cluster management existe :

```text
backup-git-repositories.sh --sync
backup-gitea.sh --backup
validation du jeu Gitea
destruction
```

Si le management est absent, le bootstrap ne tente pas de synchronisation Git fraîche et utilise le dernier jeu Gitea valide selon le comportement historique.

---

## 5. Commits de référence

### 5.1 Intégration de la sauvegarde Git au PRA

```text
d4f2e16b2969f20a015e4284ccedaac6448cc4da
feat(pra): back up inventoried repositories before destruction
```

Fichiers inclus :

```text
scripts/backup-git-repositories.sh
scripts/bootstrap-platform.sh
scripts/external-deps.tsv
scripts/git-backup-repositories.tsv
```

### 5.2 Commit généré pendant le PRA

```text
cd08f016aed59e582d3d43b4d666cdd152638207
chore(pra): renew workload registrations
```

Ce commit renouvelle les enregistrements des clusters workload après reconstruction.

### 5.3 Commit automatique de l’overlay dev

```text
071b3e063efff20ad21b00e01aeb79b2fd2e3ca8
chore(dev): deploy 2048 fb6a4af (CI)
```

### 5.4 Commit de promotion prod

```text
ed97c430b230859888729363f50a345ee167d3df
chore(prod): promote 2048 fb6a4af
```

### 5.5 Commit applicatif utilisé pour la validation post-PRA

Dans `games/2048` :

```text
fb6a4afb3e84dd058b6f38d7ce7aa50f7cd6a629
style: restore original beige page background
```

---

## 6. Validations unitaires et fonctionnelles du mécanisme Git

### 6.1 Validation du manifeste

Résultat :

```text
[RESULT] manifeste valide : 1 entrée(s)
```

### 6.2 Destination GitHub absente

La destination initialement inexistante a correctement bloqué le prévol :

```text
[STOP] Destination GitHub absente ou inaccessible : mouameng/games-2048
[RESULT] preflight=STOP errors=1 warnings=0
```

### 6.3 Destination vide

Après création du dépôt privé et vide `mouameng/games-2048` :

```text
références=0
[OK] Destination GitHub vide
[RESULT] preflight=OK repositories=1 warnings=0
```

### 6.4 Premier `--sync`

La branche `main` a été créée dans GitHub :

```text
[new branch] main -> main
[RESULT] sync=OK synced=1 errors=0 warnings=0
```

### 6.5 Idempotence

Le second `--sync` a retourné :

```text
Everything up-to-date
[RESULT] sync=OK synced=1 errors=0 warnings=0
```

Les références sont restées inchangées.

### 6.6 Purge des références propres à GitHub

Une branche et un tag temporaires ont été créés uniquement dans GitHub :

```text
github-only-prune-test
```

Le `--sync` les a supprimés automatiquement :

```text
[deleted] github-only-prune-test
```

### 6.7 Propagation Gitea vers GitHub

Une branche et un tag temporaires ont été créés dans Gitea :

```text
backup-sync-propagation-test
```

Ils ont été propagés à l’identique vers GitHub, puis supprimés de Gitea et purgés de GitHub au `--sync` suivant.

Résultat final :

```text
5f8fef086a2f2c77bc5ddc627675128b6bf7fb41 refs/heads/main
```

### 6.8 Nettoyage des répertoires temporaires

Les exécutions nominales n’ont laissé aucun répertoire :

```text
/tmp/git-backup-sync.*
```

Le trap nettoie également le répertoire après traitement d’un signal, une fois le processus enfant terminé.

---

## 7. Limite connue sur les signaux

Un test contrôlé a montré qu’un signal `TERM` envoyé uniquement au PID du script parent peut rester en attente tant qu’un processus Git enfant continue de s’exécuter.

Le résultat exact est :

```text
Nettoyage en sortie normale                         : validé
Nettoyage après TERM, une fois l’enfant terminé     : validé
Propagation de TERM au processus Git actif          : non implémentée
Arrêt autonome sur TERM ciblant uniquement le parent: non validé
```

Cette limite est reportée à un futur chantier de robustesse. Elle n’est pas considérée comme critique pour le chemin normal du PRA, où une interruption du terminal agit normalement sur le groupe de processus au premier plan.

---

## 8. PRA complet de validation

### 8.1 Journal de référence

```text
pra-git-backup-20261009-234838.log
```

Début :

```text
2026-10-09 23:48:39 +02:00
```

Fin :

```text
2026-10-10 00:01:44 +02:00
COMMAND_EXIT_CODE="0"
```

### 8.2 Prévol

Le prévol a confirmé :

- branche locale alignée avec Gitea ;
- push Git non interactif fonctionnel ;
- mirror GitHub de `gitops-lab` conforme ;
- dépendances externes conformes ;
- jeton de découverte présent en mode `600` ;
- dépôt `games/2048` découvert et inventorié ;
- destination `mouameng/games-2048` accessible ;
- DNS management conforme ;
- fichiers Git suivis propres ;
- paire CA cohérente.

### 8.3 Ordre avant destruction

Le journal prouve l’ordre suivant :

```text
[RESULT] preflight=OK repositories=1 warnings=0
[INFO] Sauvegarde Git fraiche des depots inventories avant destruction
[RESULT] sync=OK synced=1 errors=0 warnings=0
[INFO] Sauvegarde fraiche de Gitea avant destruction
[SELECT] 20261009-234854
[OK] Jeu Gitea fige pour ce PRA : 20261009-234854
Deleting cluster "gitops-management"
Deleting cluster "gitops-dev"
Deleting cluster "gitops-prod"
```

Aucune destruction n’a commencé avant la réussite des deux sauvegardes.

### 8.4 Jeu Gitea utilisé

```text
20261009-234854
```

Le jeu a été :

- créé avant destruction ;
- contrôlé ;
- sélectionné ;
- restauré dans le nouveau cluster management ;
- vérifié par empreintes sur `gitea.db` et `gitea/conf/app.ini`.

### 8.5 Reconstruction

Le PRA a recréé :

```text
gitops-management
gitops-dev
gitops-prod
```

Puis il a restauré ou reconfiguré :

- accès au registre des nœuds workload ;
- DNS du management ;
- Argo CD ;
- CA privée ;
- Sealed Secrets ;
- enregistrements workload ;
- Gitea et son PVC ;
- Root App ;
- Applications GitOps.

---

## 9. Validation post-PRA de la plateforme

### 9.1 Applications Argo CD

Les 26 Applications affichées étaient toutes :

```text
Synced / Healthy
```

La liste des Applications non conformes était vide.

Applications importantes validées :

```text
cluster-registration
game-2048-dev
game-2048-prod
gitea
gitea-external
gitea-runner
root-app
sealed-secrets
traefik
whoami
workload-dev-cluster
workload-prod-cluster
```

### 9.2 Runner Gitea Actions

État observé après PRA :

```text
StatefulSet : 1/1
Pod         : 2/2 Running
PVC         : Bound
Redémarrages: 0
```

Image du runner :

```text
docker.io/gitea/runner@sha256:66b7da94dc7dcadb2e076bec6928221336a9a637196399281c4b766fe1288242
```

### 9.3 Dépôt `games/2048`

Après restauration de Gitea, la branche était présente :

```text
5f8fef086a2f2c77bc5ddc627675128b6bf7fb41 refs/heads/main
```

La comparaison entre Gitea et GitHub était conforme.

### 9.4 Mirror de `gitops-lab`

Résultat :

```text
global=OK
token=OK
mirror=OK
refs=OK
19 références identiques
```

---

## 10. Validation CI/CD complète après PRA

### 10.1 Modification applicative

La validation a utilisé une modification visible et réversible : restauration du fond beige initial de `2048`.

```text
#e8f4ff -> #faf8ef
```

Commit :

```text
fb6a4af style: restore original beige page background
```

### 10.2 Tests locaux

Tests applicatifs :

```text
tests 4
pass 4
fail 0
```

Tests du script de digest :

```text
9 tests réussis
[RESULT] OK
```

### 10.3 Jobs Gitea Actions

#### Job `tests`

- clone du commit applicatif ;
- contrôle `HEAD == gitea.sha` ;
- 4 tests applicatifs réussis ;
- 9 tests du script de digest réussis ;
- job réussi.

#### Job `build-push`

Le tag était absent, donc l’image a été reconstruite puis publiée :

```text
tag : fb6a4af
digest OCI : sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8
```

Le digest exporté, publié et relu dans le registre était identique.

Le job a également vérifié que l’index OCI et ses manifestes enfants étaient servis.

#### Job `update-dev-overlay`

Le job a :

- validé le digest ;
- cloné `games/2048` ;
- cloné `gitops-lab` avec `ci-bot` ;
- modifié uniquement l’overlay dev ;
- créé le commit `071b3e0` ;
- poussé sur `gitops-lab/main` ;
- terminé avec succès.

### 10.4 Déploiement dev

Résultat :

```text
game-2048-dev : Synced/Healthy
Deployment    : 1/1
Pod           : 1/1 Running, 0 redémarrage
```

Image :

```text
gitea.local/gitea_admin/2048@sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8
```

Validation visuelle après `Ctrl+F5` : fond beige sur `2048.dev.local`.

Pendant cette phase, prod restait sur le digest précédent et conservait le fond bleu clair.

### 10.5 Promotion prod

Le digest validé sur dev a été recopié dans l’overlay prod avec :

```text
ci/set-overlay-digest.sh
```

Commit distinct :

```text
ed97c43 chore(prod): promote 2048 fb6a4af
```

Le nœud prod a pu précharger l’image. Argo CD a convergé, puis le Deployment a terminé son rollout.

État final :

```text
dev  = gitea.local/gitea_admin/2048@sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8
prod = gitea.local/gitea_admin/2048@sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8
```

Validation visuelle après `Ctrl+F5` : fond beige sur `2048.prod.local`.

### 10.6 Mirror après promotion

Le mirror GitHub de `gitops-lab` est resté conforme :

```text
global=OK
token=OK
mirror=OK
refs=OK
19 références identiques
```

---

## 11. Matrice de validation finale

```text
Assistant Git HTTPS local pour Gitea             VALIDÉ
Push Gitea non interactif                         VALIDÉ
Inventaire explicite des dépôts                   VALIDÉ
Découverte dynamique des organisations Gitea      VALIDÉ
Détection des dépôts non inventoriés              VALIDÉ
Contrôle des destinations GitHub                  VALIDÉ
Premier sync Gitea vers GitHub                    VALIDÉ
Idempotence du sync                               VALIDÉ
Purge des références propres à GitHub             VALIDÉ
Propagation et suppression des refs Gitea         VALIDÉ
Comparaison exacte heads/tags                     VALIDÉ
Nettoyage nominal des clones temporaires          VALIDÉ
Intégration du prévol au bootstrap                 VALIDÉ
Sync Git avant sauvegarde Gitea                    VALIDÉ
Sauvegarde fraîche Gitea avant destruction         VALIDÉ
PRA complet                                       VALIDÉ
Restauration Gitea                                VALIDÉ
Restauration du runner Gitea Actions              VALIDÉ
Applications Argo CD Synced/Healthy               VALIDÉ
CI exécutée après PRA                             VALIDÉ
Tests applicatifs et techniques                   VALIDÉ
Build et publication OCI                         VALIDÉ
Validation du digest OCI                         VALIDÉ
Mise à jour automatique de l’overlay dev         VALIDÉ
Déploiement workload-dev                         VALIDÉ
Promotion manuelle vers prod                     VALIDÉ
Déploiement workload-prod                        VALIDÉ
Contrôle visuel dev et prod                      VALIDÉ
Mirror GitHub de gitops-lab                      VALIDÉ
Propagation TERM vers un enfant Git              REPORTÉE
TLS propre pour 2048.dev.local et prod           REPORTÉ
```

---

## 12. Points non bloquants reportés

### 12.1 Gestion avancée des signaux

La propagation d’un signal ciblant uniquement le processus parent vers un processus Git enfant actif reste à implémenter si ce besoin devient pertinent.

### 12.2 TLS de `2048.dev.local` et `2048.prod.local`

Le test `curl` avec vérification TLS a échoué avec :

```text
SSL: no alternative certificate subject name matches target hostname '2048.dev.local'
```

Le navigateur affiche également « Non sécurisé ».

Le service applicatif fonctionne, mais les certificats ne couvrent pas encore les noms `2048.dev.local` et `2048.prod.local`.

Ce point est reporté au chantier DNS global / PKI.

### 12.3 Durée et verbosité du PRA

Le PRA comporte désormais de nombreuses gardes et validations. Une future version pourra :

- mesurer les durées par phase ;
- réduire les contrôles redondants ;
- produire un résumé final plus synthétique ;
- séparer journal utilisateur et journal détaillé ;
- conserver le même niveau de sécurité sans allonger inutilement le chemin nominal.

---

## 13. Décisions structurantes pour la v1.3.5

### 13.1 Réorganisation locale des clones

L’option retenue est une arborescence locale par forge, propriétaire et dépôt :

```text
~/lab/gitea/
├── games/
│   ├── 2048/
│   └── snake/
└── gitea_admin/
    └── gitops-lab/
```

Ordre de migration prévu :

1. créer la racine `~/lab/gitea/games` ;
2. migrer `~/lab/2048` vers `~/lab/gitea/games/2048` ;
3. vérifier scripts, remotes, alias et documentation ;
4. créer ou préparer les futurs dépôts de l’organisation `games` ;
5. migrer ensuite `~/lab/gitops-lab` vers `~/lab/gitea/gitea_admin/gitops-lab` ;
6. mettre à jour les chemins communs et les scripts de reprise.

Cette convention reste indépendante du futur nom DNS global : `gitea` représente la forge logique, pas nécessairement l’hôte DNS final.

### 13.2 Scripts mutualisés pour l’organisation `games`

Organisation cible dans `gitops-lab` :

```text
scripts/games/
├── games.tsv
├── release-dev.sh
└── promote-prod.sh
```

Interfaces cibles :

```text
scripts/games/release-dev.sh <jeu> "<message de commit>"
scripts/games/promote-prod.sh <jeu>
```

Responsabilités :

#### `release-dev.sh`

- identifier le jeu dans l’inventaire ;
- trouver son clone local sous `~/lab/gitea/games/<jeu>` ;
- vérifier le dépôt et le diff ;
- lancer les tests locaux communs ;
- créer et pousser le commit applicatif ;
- attendre la CI Gitea Actions ;
- attendre le digest OCI ;
- attendre la mise à jour automatique de l’overlay dev ;
- rafraîchir Argo CD ;
- attendre `Synced/Healthy` et le rollout ;
- vérifier le digest réellement déployé ;
- confirmer que prod n’a pas changé.

#### `promote-prod.sh`

- lire le digest validé dans l’overlay dev ;
- vérifier l’état de dev ;
- précharger l’image sur le nœud prod ;
- modifier uniquement l’overlay prod ;
- créer et pousser un commit de promotion ;
- rafraîchir Argo CD ;
- attendre `Synced/Healthy` et le rollout ;
- vérifier l’égalité finale dev/prod ;
- contrôler le mirror GitHub.

### 13.3 Contrat commun des dépôts `games`

Convention cible :

```text
Dockerfile
ci/test.sh
ci/set-overlay-digest.sh
```

Le script `ci/test.sh` masquera les spécificités technologiques de chaque jeu.

Exemple pour `2048` :

```bash
#!/usr/bin/env bash
set -euo pipefail

node --test tests/*.test.mjs
bash ci/test-set-overlay-digest.sh
```

### 13.4 Workflow commun à l’organisation

Une évolution ultérieure pourra introduire un dépôt central de workflows, par exemple :

```text
games/ci-workflows
└── .gitea/scoped_workflows/games-ci.yaml
```

Cette migration sera traitée séparément. Le workflow `2048` actuellement validé sert de référence fonctionnelle et ne doit pas être remplacé avant que le mécanisme mutualisé soit testé avec au moins un second jeu.

---

## 14. Point de reprise opérationnel

### État final attendu

```text
gitops-lab main : ed97c43 ou commit ultérieur documenté
2048 main       : fb6a4af ou commit ultérieur documenté
2048 dev image  : sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8
2048 prod image : sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8
Argo CD         : 26 Applications Synced/Healthy lors du contrôle final
runner          : StatefulSet 1/1, pod 2/2 Running, PVC Bound
mirror GitHub   : global=OK, 19 références identiques
```

### Contrôles rapides

```bash
cd ~/lab/gitops-lab

scripts/backup-git-repositories.sh --preflight
scripts/check-external-deps.sh --check
scripts/check-github-mirror.sh --check

kubectl --context kind-gitops-management -n argocd \
  get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

kubectl --context kind-gitops-dev -n game-2048 \
  get deployment game-2048 \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

kubectl --context kind-gitops-prod -n game-2048 \
  get deployment game-2048 \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

---

## 15. Clôture

La v1.3.4 atteint son objectif : la source applicative `games/2048` est sauvegardée vers GitHub avant un PRA, la restauration du lab conserve l’ensemble des composants nécessaires à la CI et au GitOps, et une modification applicative a été testée de bout en bout après PRA jusqu’à la production.

La prochaine version, v1.3.5, portera principalement sur :

1. la réorganisation locale des clones sous `~/lab/gitea/<propriétaire>/<dépôt>` ;
2. la migration d’abord du périmètre `games`, puis de `gitops-lab` ;
3. la mutualisation des scripts de livraison dev et de promotion prod ;
4. la préparation d’un contrat commun pour les futurs jeux ;
5. la préparation d’un futur workflow Gitea commun à l’organisation `games`.

La v1.3.4 peut être taguée et publiée après ajout de ce document au dépôt et vérification finale de l’alignement Gitea/GitHub.
