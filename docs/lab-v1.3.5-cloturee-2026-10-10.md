# Lab GitOps v1.3.5 — Réorganisation du socle et PRA validé

**Date de clôture technique :** 10 octobre 2026
**Statut :** PRA validé, version prête à être taguée et publiée
**Tag prévu :** `v1.3.5`
**Dépôt principal Gitea :** `platform/infrastructure-devops`
**Dépôt de secours GitHub :** `mouameng/infrastructure-devops`
**Nom fonctionnel :** Socle Infrastructure DevOps du lab

---

## 1. Objet de la version

La version v1.3.5 consolide la nouvelle identité du socle Infrastructure DevOps du lab et valide sa résilience par un PRA complet.

Les objectifs principaux étaient :

- supprimer les redondances de nommage liées au terme `lab` ;
- regrouper les clones Gitea locaux sous une arborescence reflétant les organisations de la forge ;
- transférer et renommer le dépôt historique `gitea_admin/gitops-lab` ;
- adapter Argo CD, les scripts PRA, la CI et les outils locaux à la nouvelle identité ;
- renommer le dépôt de secours GitHub et recréer le push mirror ;
- vérifier la chaîne CI de `games/2048` ;
- rejouer un PRA complet avant toute évolution supplémentaire de l’organisation `games`.

---

## 2. Nomenclature retenue

### 2.1 Organisation des dépôts Gitea

```text
Gitea
├── games
│   └── 2048
└── platform
    └── infrastructure-devops
```

### 2.2 Arborescence locale

```text
~/lab/gitea/
├── games/
│   └── 2048/
└── platform/
    └── infrastructure-devops/
```

### 2.3 Identité fonctionnelle

```text
Organisation Gitea : platform
Dépôt Gitea        : infrastructure-devops
Description        : Socle Infrastructure DevOps du lab
Chemin local       : ~/lab/gitea/platform/infrastructure-devops
Dépôt GitHub       : mouameng/infrastructure-devops
```

Le terme **socle** reste volontairement en français dans la description fonctionnelle. Les noms techniques et identifiants restent en anglais, conformément à la nomenclature générale du lab.

---

## 3. Migration du dépôt de plateforme

### 3.1 Ancienne identité

```text
Gitea       : gitea_admin/gitops-lab
Chemin local: ~/lab/gitops-lab
GitHub      : mouameng/gitops-lab
```

### 3.2 Nouvelle identité

```text
Gitea       : platform/infrastructure-devops
Chemin local: ~/lab/gitea/platform/infrastructure-devops
GitHub      : mouameng/infrastructure-devops
```

### 3.3 Cinématique appliquée

1. Création de l’organisation Gitea `platform`.
2. Transfert du dépôt `gitea_admin/gitops-lab` vers `platform/gitops-lab`.
3. Renommage en `platform/infrastructure-devops`.
4. Mise à jour du remote local `gitea`.
5. Migration des `repoURL` Argo CD, AppProjects et Root App.
6. Adaptation des scripts `gitea-publish.sh` et `check-github-mirror.sh`.
7. Publication du commit de migration :

```text
c21a6550b960797fdda007f5314e33b8cfbcd23e
refactor(platform): rename GitOps repository
```

8. Bascule de la Root App vivante vers la nouvelle URL.
9. Convergence de l’ensemble des Applications Argo CD.
10. Déplacement du clone local vers son chemin définitif.

### 3.4 Éléments préservés

Le transfert et le renommage ont conservé :

- l’identifiant du dépôt Gitea ;
- la branche `main` ;
- l’historique Git ;
- les tags et releases ;
- Gitea Actions ;
- les packages ;
- le push mirror ;
- les permissions nécessaires aux opérations Git et à `ci-bot`.

---

## 4. Choix de visibilité

L’organisation `platform` a d’abord été créée en visibilité privée. Ce choix a rendu l’accès Git anonyme impossible pour Argo CD, qui ne disposait d’aucun secret de dépôt.

Les symptômes observés étaient :

```text
Applications Argo CD : Unknown
Condition             : ComparisonError
Cause                 : ancienne URL redirigée en HTTP 301
Accès nouvelle URL    : authentification requise
Secrets repository   : aucun
Secrets repo-creds   : aucun
```

La visibilité de l’organisation `platform` a donc été passée à **public**, comme le dépôt, afin de conserver le modèle historique :

- lecture anonyme par Argo CD ;
- écriture authentifiée ;
- secrets, clés et jetons hors Git ;
- absence de nouvelle dépendance secrète pour le PRA.

Après correction, la nouvelle URL interne a été validée depuis WSL et depuis le cluster management :

```text
http://gitea-http.gitea.svc.cluster.local:3000/platform/infrastructure-devops.git
```

---

## 5. Migration Argo CD

Les références actives suivantes ont été migrées :

- Applications Argo CD adossées au dépôt interne ;
- AppProject `applications` ;
- AppProject `infrastructure` ;
- Root App ;
- source de valeurs de l’Application Gitea ;
- scripts de publication et de contrôle du mirror.

### Résultat

Après publication et bascule de la Root App :

```text
Anciennes URL vivantes : 0
Applications Unknown  : 0
Applications OutOfSync: 0
Applications non Healthy: 0
```

Les 26 Applications observées ont convergé en état :

```text
Synced / Healthy
```

---

## 6. Migration de la CI `games/2048`

Deux workflows contenaient encore l’ancienne identité :

```text
.gitea/workflows/ci.yaml
.gitea/workflows/runner-smoke-secrets.yaml
```

Les clones du dépôt d’exploitation ont été migrés vers :

```text
platform/infrastructure-devops
```

Commit publié dans `games/2048` :

```text
fea0a492c4e9b2c5e0114b9f10716c83e2dda268
ci: target platform infrastructure repository
```

### Validation de la chaîne CI

Le run Gitea Actions `#11` a terminé avec succès :

```text
registry          : success
cleanup-registry  : success
gitops-bot        : success
```

Le job `gitops-bot` a produit le commit GitOps automatique :

```text
47ea8b5b63d42a6583493a66f06c0fed57a33885
chore(dev): deploy 2048 fea0a49 (CI)
```

Un seul fichier a été modifié :

```text
applications/games/2048/overlays/dev/kustomization.yaml
```

L’overlay prod n’a pas été modifié automatiquement.

### Digests validés

```text
Dev : sha256:7f3e1de6324469d9b7022eab6603b38b4582de10788a0b6605d0dbe5c4d7741f
Prod: sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8
```

Les Deployments réels utilisaient les digests déclarés dans Git et les deux Applications étaient `Synced/Healthy`.

---

## 7. Déplacement local et outils hors dépôt

Le clone principal a été déplacé vers :

```text
~/lab/gitea/platform/infrastructure-devops
```

Les outils locaux suivants ont été adaptés :

```text
~/lab/tools/patch-bootstrap-external-deps.py
~/lab/tools/patch-bootstrap-dns.py
~/lab/tools/ci/update-dev-overlay.job.yaml
```

Les sauvegardes locales créées lors de ces adaptations sont conservées hors des fichiers actifs.

L’audit final a confirmé :

```text
~/lab/2048     : absent
~/lab/gitops-lab: absent
Références actives vers gitea_admin/gitops-lab: aucune
Références actives vers les anciens chemins locaux: aucune
```

---

## 8. Renommage du dépôt GitHub et push mirror

Le dépôt de secours a été renommé :

```text
mouameng/gitops-lab
    -> mouameng/infrastructure-devops
```

Le remote local `origin` a été mis à jour :

```text
git@github.com:mouameng/infrastructure-devops.git
```

Le script `check-github-mirror.sh` a été adapté et publié avec le commit :

```text
683105bddc8098398c3bc880382a96350c31ae73
chore(mirror): rename GitHub backup repository
```

Le push mirror Gitea a été supprimé puis recréé vers la nouvelle destination GitHub, avec :

```text
Intervalle    : 1h0m0s
Sync on commit: active
Erreur        : aucune
Références    : 21 branches et tags identiques
```

Le PAT GitHub actif expire le **6 janvier 2027**.

---

## 9. Amélioration du bootstrap PRA

Une option d’aide a été ajoutée au bootstrap :

```text
scripts/bootstrap-platform.sh --help
```

Modes documentés :

```text
--help       Afficher l’aide sans effectuer de contrôle
--plan       Afficher le plan de reconstruction sans modifier le lab
--preflight  Exécuter uniquement les contrôles préalables au PRA
sans option  Exécuter le PRA interactif complet
```

Commit publié :

```text
be8dd7148f3c7117c21fa8a781fd0e3c83974f63
feat(pra): add bootstrap help
```

---

## 10. Sauvegardes de référence

### Sauvegarde post-migration avant PRA

```text
20261010-033112
```

Cette sauvegarde a été créée après :

- la nouvelle organisation `platform` ;
- le renommage du dépôt Gitea ;
- le renommage du dépôt GitHub ;
- la recréation du push mirror.

### Sauvegarde figée par le PRA

```text
20261010-034010
```

Elle a été créée immédiatement avant la destruction des clusters et utilisée pour la restauration effective.

---

## 11. PRA v1.3.5 validé

### 11.1 Prévol

Le prévol exécuté depuis le nouveau chemin a validé :

- la branche `main` alignée ;
- le jeton Gitea et les droits d’écriture ;
- le rendu Gitea ;
- le push mirror GitHub ;
- les dépendances hors source de vérité ;
- les jetons CI et registre ;
- les digests OCI ;
- les sauvegardes Git de `games/2048` ;
- le DNS management ;
- les fichiers suivis propres ;
- le hash administrateur Argo CD ;
- la paire de CA privée.

Résultat :

```text
global=OK
ok=26
warn=0
crit=0
```

### 11.2 Destruction et reconstruction

Le PRA a détruit puis recréé :

```text
gitops-management
gitops-dev
gitops-prod
```

Les opérations validées comprennent :

- création des clusters Kind ;
- configuration du registre sur les nœuds workload ;
- restauration du DNS management ;
- installation d’Argo CD ;
- restauration de la CA privée ;
- restauration de la clé Sealed Secrets ;
- génération et validation des candidats d’enregistrement ;
- restauration des données Gitea ;
- installation directe temporaire de Gitea avant reprise par Argo CD ;
- publication des nouveaux enregistrements dev/prod ;
- application de `cluster-registration` ;
- création des secrets de clusters ;
- application de la Root App ;
- validation Whoami et des Ingress ;
- synchronisation de Gitea et de son exposition externe.

Commit PRA publié :

```text
d8323ef428702492dfaa66dce56f86f615b4a032
chore(pra): renew workload registrations
```

### 11.3 Validation post-PRA

Les deux dépôts ont été retrouvés :

```text
platform/infrastructure-devops
games/2048
```

Pour chacun :

```text
default_branch: main
has_actions   : true
```

Le push mirror restauré a été validé :

```text
PAT valide
1 push mirror
aucune erreur
sync_on_commit actif
21 références identiques
```

Les 26 Applications Argo CD étaient :

```text
Synced / Healthy
```

### 11.4 Runner après PRA

Le runner a été restauré avec :

```text
StatefulSet : 1/1
Pod         : gitea-runner-0
Conteneurs  : 2/2 Running
Redémarrages: 0
Runner      : lab-games
Version     : v3.5.0
Labels      : lab-node22, lab-docker
```

Les journaux ont confirmé :

```text
Runner registered successfully
Docker is ready
runner: lab-games ... declare successfully
```

### 11.5 Smoke test post-PRA

Le run `#11` a été relancé en tentative `#2` sans nouveau commit.

Résultat :

```text
Statut           : Succès
Durée totale     : 40 s
Jobs réussis     : 3/3
registry         : 9 s
cleanup-registry : 1 s
gitops-bot       : 30 s
```

Ce smoke test valide après reconstruction :

- le runner `lab-games` ;
- les labels `lab-docker` et `lab-node22` ;
- Docker et le registre Gitea ;
- les secrets `REGISTRY_TOKEN` et `GITOPS_WRITE_TOKEN` ;
- le nettoyage du paquet jetable ;
- le clone interne de `platform/infrastructure-devops` ;
- les droits de création et suppression d’une branche jetable par `ci-bot`.

---

## 12. État de référence à figer

### Commit courant à taguer

```text
d8323ef428702492dfaa66dce56f86f615b4a032
```

### Tag à créer

```text
v1.3.5
```

### Titre de release proposé

```text
v1.3.5 — Réorganisation du socle et PRA validé
```

### Vérifications avant création du tag

- confirmer que le clone local, Gitea et GitHub pointent sur `d8323ef` ;
- intégrer le présent document dans le dépôt ;
- décider du traitement des deux autres documents v1.3.3 encore non suivis ;
- committer le document de clôture ;
- taguer le commit contenant la documentation finale, plutôt que `d8323ef` directement ;
- vérifier la réplication du tag vers GitHub ;
- créer la release Gitea.

> Important : `d8323ef` est le commit fonctionnel validé par le PRA. Si ce document est ajouté avant le gel, le tag `v1.3.5` devra viser le commit documentaire final descendant de `d8323ef`.

---

## 13. Points volontairement inchangés

Les identifiants suivants restent associés au lab et ne sont pas des références obsolètes au dépôt :

```text
~/.config/gitops-lab
~/.local/share/gitops-lab
gitops-lab-root-ca
gitops-lab-ca-issuer
kind-gitops-management
kind-gitops-dev
kind-gitops-prod
```

Le registre applicatif reste également sous l’espace historique :

```text
gitea.local/gitea_admin/2048
```

Son éventuelle réorganisation n’appartient pas au périmètre validé de la v1.3.5.

---

## 14. Suite prévue en v1.3.6

La v1.3.6 pourra reprendre les travaux sur l’organisation `games`, uniquement après le gel de la v1.3.5.

### Pistes retenues

- mutualiser prudemment les scripts communs aux jeux ;
- étudier une organisation sous `scripts/games/` ;
- introduire un inventaire `games.tsv` si son utilité est confirmée ;
- cadrer `release-dev.sh` ;
- cadrer `promote-prod.sh` ;
- conserver la promotion vers prod manuelle ;
- préparer l’ajout futur de jeux comme Snake et Hextris ;
- éviter une abstraction prématurée tant qu’un seul jeu sert de référence ;
- préserver la compatibilité PRA à chaque incrément.

### Principes à conserver

```text
Un tag existant n'est ni réécrit ni reconstruit.
Le digest doit être servi avant son écriture dans l'overlay dev.
La promotion vers prod reste manuelle.
Les changements sont validés par dry-run et contrôles ciblés.
Le PRA reste une porte de validation avant toute nouvelle restructuration majeure.
```

---

## 15. Conclusion

La v1.3.5 établit une identité claire et durable pour le socle du lab :

```text
platform/infrastructure-devops
```

La migration a été validée à trois niveaux :

1. **fonctionnement courant** : Argo CD, CI, dev et prod ;
2. **réplication** : push mirror vers `mouameng/infrastructure-devops` ;
3. **résilience** : PRA complet avec restauration de Gitea, des clusters, d’Argo CD, du runner et des workflows.

La version peut être figée après intégration de cette documentation et création du tag `v1.3.5` sur le commit documentaire final.
