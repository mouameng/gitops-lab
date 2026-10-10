# Lab v1.3.7 clôturée le 2026-10-10

## 1. Objet du document

Ce document constitue la référence de clôture de la version **v1.3.7** du lab `platform/infrastructure-devops`.

Il décrit :

- le périmètre traité dans la version ;
- les décisions de conception prises ;
- les modifications apportées au dépôt et au PRA ;
- les incidents rencontrés et leurs causes établies ;
- les validations exécutées ;
- l’état final du lab ;
- les éléments nécessaires pour reprendre les travaux ultérieurement ;
- les chantiers explicitement reportés à une version future.

Le document distingue volontairement les faits observés, les causes démontrées et les sujets encore à traiter.

---

## 2. Résumé de la version

La v1.3.7 a commencé comme un chantier de renommage des répertoires locaux du lab :

```text
~/.config/gitops-lab     -> ~/.config/lab
~/.local/share/gitops-lab -> ~/.local/share/lab
```

Ce chantier a été complété par une amélioration importante du PRA :

- centralisation des chemins locaux dans `scripts/lib/lab-paths.sh` ;
- conservation temporaire des anciens répertoires comme garde de retour arrière ;
- maintien d’un mode `--preflight` strictement non modifiant ;
- exécution automatique des sauvegardes préparatoires dans le PRA réel ;
- déplacement de la confirmation interactive juste avant la destruction ;
- annulation propre avec conservation des sauvegardes ;
- validation automatique de l’état restauré ;
- correction d’une course TLS entre cert-manager, Argo CD et Traefik ;
- attente bornée de la convergence finale des Applications Argo CD ;
- validation finale par un PRA complet terminé avec le code `0`.

Le PRA final a produit :

```text
[RESULT] PRA=OK backup=20261010-160534 commit=88f39a93e980 apps=26
```

---

## 3. Versions et références Git

### 3.1 Point de départ

La version précédente était la v1.3.6.

```text
tag annoté : v1.3.6
objet du tag : 45ee4cd556188e6bc075636f32820c9a074985b7
commit : c8ada9a8169323ba2ceaa3049b3f75d92d107673
objet : docs(v1.3.6): fix wording and note the document renaming
```

### 3.2 Commits de la v1.3.7

```text
be9f0c29a85d10c46c818ce5982e0cb5c44085b4  refactor(paths): centralize local lab directories
5814b823c4afd55d9698c43901476d4d5fbde38a  chore(pra): renew workload registrations
239946967777d511f7d5068c0d357c3479cbc4c1  feat(pra): validate restore before completion
51bc0eca64d8a47317534adb6ee6eaa5477d308a  chore(pra): renew workload registrations
ca4f21679c737631a9b123d9cda83270cef34524  fix(tls): order certificate before ingress route
84b1bfd3c5556b8cefe65f085b69683d3269f67c  chore(pra): renew workload registrations
0bcd6927be8dcd28c30fd7dd208a1f353e27cfcc  fix(pra): wait for Argo CD convergence
88f39a93e980c13a9aef0e8e8209df22dc599b1f  chore(pra): renew workload registrations
```

Le document de clôture doit être commité après `88f39a9`. Le futur tag `v1.3.7` devra pointer sur le commit documentaire final, et non directement sur le dernier commit PRA.

---

## 4. Décision de nommage des chemins locaux

### 4.1 Décision

Le nom local `gitops-lab` a été remplacé par `lab` dans les chemins de configuration et de données :

```text
~/.config/lab
~/.local/share/lab
```

Le nom `lab` représente le sandbox local et reste cohérent avec le répertoire de travail :

```text
~/lab
```

Les termes `platform` et `infrastructure` restent réservés aux objets qui décrivent réellement la plateforme ou son infrastructure.

### 4.2 Chemins retenus

```text
LAB_CONFIG_DIR=~/.config/lab
LAB_DATA_DIR=~/.local/share/lab
```

Les sous-répertoires principaux incluent notamment :

```text
~/.config/lab/
~/.config/lab/registration-candidates/
~/.local/share/lab/backups/gitea/
~/.local/share/lab/logs/
~/.local/share/lab/dns-backups/
~/.local/share/lab/script-backups/
```

### 4.3 Factorisation

Le fichier suivant a été ajouté :

```text
scripts/lib/lab-paths.sh
```

Ce fichier devient la source commune des chemins locaux utilisés par les scripts du lab.

Le but est d’éviter :

- la duplication de chemins dans de nombreux scripts ;
- les divergences lors d’un prochain renommage ;
- les dépendances implicites à un ancien nom local ;
- les oublis lors des contrôles PRA.

### 4.4 Scripts adaptés

Les chemins centralisés ont été repris dans les scripts de sauvegarde, restauration, bootstrap, publication, DNS, registre et contrôles externes.

Les principaux fichiers concernés sont :

```text
scripts/backup-git-repositories.sh
scripts/backup-gitea.sh
scripts/backup-sealed-secrets-key.sh
scripts/bootstrap-management.sh
scripts/bootstrap-platform.sh
scripts/bootstrap-workload.sh
scripts/check-external-deps.sh
scripts/check-github-mirror.sh
scripts/configure-management-dns.sh
scripts/configure-workload-registry.sh
scripts/ensure-games-pull-secret.sh
scripts/gitea-publish.sh
scripts/restore-gitea.sh
scripts/validate-registration-candidates.sh
```

### 4.5 Ancien emplacement

Les anciens répertoires `~/.config/gitops-lab` et `~/.local/share/gitops-lab` ont été conservés temporairement pendant la validation de la v1.3.7.

Ils ne doivent être supprimés qu’après :

- validation du PRA avec les nouveaux chemins ;
- contrôle de l’absence d’accès résiduel ;
- vérification que les sauvegardes, jetons, journaux et candidats d’enregistrement sont bien utilisés depuis les nouveaux emplacements.

---

## 5. Cinématique du PRA

### 5.1 Problème initial

Avant la v1.3.7, la confirmation interactive de destruction était demandée avant les sauvegardes préparatoires.

Cela avait deux conséquences :

- après le choix de destruction, les sauvegardes étaient exécutées puis la destruction s’enchaînait automatiquement ;
- il n’existait plus de point de contrôle humain entre la validation des sauvegardes et le premier `kind delete cluster`.

### 5.2 Décision retenue

Les sauvegardes préparatoires sont désormais :

- absentes du mode `--preflight` ;
- automatiques dans le PRA réel ;
- exécutées avant la confirmation destructive.

### 5.3 Mode `--preflight`

Le mode `--preflight` reste strictement non modifiant :

```text
contrôles locaux et externes
-> contrôle du dépôt de secours GitHub
-> contrôle des dépendances hors source de vérité
-> backup-git-repositories.sh --preflight
-> contrôle du registre games
-> contrôle du rendu DNS
-> contrôle Git
-> contrôle de la CA et des prérequis
-> sortie sans sauvegarde ni interaction
```

Résultat attendu :

```text
[OK] Prévol terminé ; aucune action Kind ou Kubernetes appliquée
```

Le prévol validé sur le commit `ca4f216` a retourné le code `0` sans sauvegarde, interaction, destruction ou validation post-PRA.

### 5.4 PRA réel

La séquence retenue est :

```text
prévol complet
-> calcul du périmètre à détruire
-> vérification de la présence d’un terminal interactif
-> remédiation éventuelle du mirror GitHub
-> backup-git-repositories.sh --sync
-> backup-gitea.sh --backup
-> extraction du jeu [SELECT]
-> validation du format de l’identifiant
-> backup-gitea.sh --validate
-> gel du jeu Gitea pour le PRA
-> affichage du périmètre
-> confirmation interactive
-> destruction si le choix vaut 2
-> annulation propre si le choix vaut 1
```

### 5.5 Annulation après sauvegardes

Le choix `1` conserve les sauvegardes préparatoires et termine avec le code `0` :

```text
[INFO] Destruction refusée par l'utilisateur
[OK] Jeu Gitea conservé : AAAAMMJJ-HHMMSS
[RESULT] PRA annulé avant destruction ; sauvegardes préparatoires conservées
```

Ce comportement a été validé avec le jeu :

```text
20261010-150114
```

Les clusters sont restés strictement inchangés :

```text
gitops-management
gitops-dev
gitops-prod
```

---

## 6. Validation automatique post-PRA

### 6.1 Ancien comportement

Le bootstrap se terminait auparavant par :

```text
[INFO] Connexion et contenu des depots encore a verifier
```

Cette note se trouvait à la dernière ligne du script. Aucun contrôle ni résultat final ne la suivait.

Le texte provenait des premières versions du PRA, quand la restauration Gitea était encore suivie de validations manuelles.

### 6.2 Nouveau validateur

Le script suivant a été ajouté :

```text
scripts/validate-post-pra.sh
```

Il est appelé automatiquement par `bootstrap-platform.sh` avec le jeu Gitea utilisé :

```text
validate-post-pra.sh --backup "$GITEA_GAME"
```

### 6.3 Contrôles réalisés

Le validateur contrôle :

1. les dépôts Gitea restaurés ;
2. la branche par défaut et l’activation de Gitea Actions ;
3. l’alignement de `platform/infrastructure-devops/main` avec le `HEAD` local ;
4. l’alignement des dépôts applicatifs obligatoires entre Gitea et GitHub ;
5. la conformité de toutes les Applications Argo CD ;
6. l’état du runner Gitea Actions ;
7. la présence des marqueurs fonctionnels du runner.

### 6.4 Endpoints Gitea utilisés

Le jeton de découverte a les droits nécessaires sur les endpoints d’organisation :

```text
/api/v1/orgs/games/repos
/api/v1/orgs/platform/repos
```

Les endpoints détaillés de dépôt retournent `403` avec ce jeton :

```text
/api/v1/repos/games/2048
/api/v1/repos/platform/infrastructure-devops
```

Il n’a pas été nécessaire d’augmenter les droits du jeton. Le validateur utilise les endpoints d’organisation, puis `git ls-remote` pour les SHA.

### 6.5 Résultat final

Le validateur émet un résultat unique :

```text
[RESULT] PRA=OK backup=<jeu> commit=<sha-court> apps=<nombre>
```

Le PRA final a émis :

```text
[RESULT] PRA=OK backup=20261010-160534 commit=88f39a93e980 apps=26
```

---

## 7. Correction de la course TLS Gitea

### 7.1 Symptôme historique

Plusieurs PRA avaient présenté une indisponibilité TLS temporaire de `gitea.local` après reconstruction.

Le symptôme était ensuite résolu sans intervention et avait initialement été classé en cause inconnue.

Pendant la v1.3.7, le validateur automatique a capturé l’erreur :

```text
curl: (60) SSL: no alternative certificate subject name matches target hostname 'gitea.local'
```

Après convergence :

- le certificat Kubernetes contenait `DNS:gitea.local` ;
- le certificat présenté contenait aussi `DNS:gitea.local` ;
- les empreintes SHA-256 étaient identiques ;
- `curl` retournait HTTP 200.

### 7.2 Cause établie

Les journaux Traefik ont montré :

```text
Error configuring TLS error="secret gitea/gitea-local-tls does not exist"
```

La chronologie était :

```text
IngressRoute observée par Traefik
-> Secret gitea-local-tls encore absent
-> configuration TLS impossible
-> certificat par défaut ou non correspondant temporairement présenté
-> cert-manager crée le Secret
-> Traefik converge ensuite
```

Le problème n’était pas un cache `curl` et ne devait pas être masqué par `curl -k` ou par un retry arbitraire.

### 7.3 Limite Argo CD identifiée

Le `Certificate` cert-manager était uniquement `Synced` dans la vue persistante de l’Application, sans santé calculée.

Sans health check, des sync waves seules auraient imposé un ordre d’application, mais n’auraient pas garanti l’attente de `Ready=True`.

### 7.4 Health check Certificate

Le fichier suivant a été ajouté :

```text
applications/argocd/argocd-cm-health.yaml
```

Il configure :

```text
resource.customizations.health.cert-manager.io_Certificate
```

La logique est :

```text
Issuing=True -> Progressing
Ready=True   -> Healthy
Ready=False  -> Degraded
absence de condition terminale -> Progressing
```

Le health check est appliqué pendant `bootstrap-management.sh`, puis `argocd-application-controller` est redémarré de façon contrôlée afin de charger la personnalisation.

### 7.5 Sync waves

Les annotations suivantes ont été ajoutées :

```text
Certificate gitea-local : sync-wave -10
IngressRoute gitea      : sync-wave 0
```

La barrière devient :

```text
Certificate appliqué
-> cert-manager émet le certificat
-> Secret gitea-local-tls créé
-> Certificate évalué Healthy par Argo CD
-> passage à la wave 0
-> création de l’IngressRoute
-> Traefik trouve immédiatement le Secret
```

### 7.6 Validation probante

Le journal détaillé Argo CD a montré :

```text
Certificate Missing
-> Certificate Progressing
-> Certificate Healthy
-> IngressRoute créée
```

Lors du PRA final :

```text
[OK] aucune erreur Traefik sur gitea-local-tls
```

La correction TLS est donc validée comme correction structurelle d’ordonnancement, et non comme simple temporisation.

---

## 8. Attente de convergence des Applications Argo CD

### 8.1 Problème observé

Après la correction TLS, le validateur a initialement échoué car quatre Applications étaient encore `Synced/Progressing` :

```text
game-2048-dev
game-2048-prod
whoami
whoami-prod
```

Les rollouts Kubernetes et les contrôles HTTP étaient pourtant déjà réussis.

La chronologie a montré que les Applications passaient ensuite naturellement à `Healthy` lorsque les événements Ingress et Deployment déclenchaient la réconciliation Argo CD.

### 8.2 Nature du problème

Contrairement à la course TLS, il ne s’agissait pas d’un défaut de modèle ou d’ordonnancement.

Il s’agissait de la convergence asynchrone normale du processus CD.

### 8.3 Attente bornée

Le validateur attend maintenant :

```text
ARGOCD_WAIT_TIMEOUT=300
ARGOCD_WAIT_INTERVAL=5
```

La boucle :

- lit toutes les Applications ;
- affiche les Applications non conformes ;
- continue tant que certaines ne sont pas `Synced/Healthy` ;
- termine immédiatement lorsque toutes sont conformes ;
- échoue si le délai de 300 secondes est dépassé ;
- refuse les valeurs de paramètres invalides.

### 8.4 Validation finale

Pendant le PRA final, la boucle a observé la convergence sur 12 tentatives.

Les Applications ont disparu progressivement de la liste :

```text
whoami
whoami-prod
game-2048-dev
game-2048-prod
```

Le résultat final a été :

```text
[OK] Applications Argo CD conformes : 26 Synced/Healthy
```

---

## 9. Runner Gitea Actions

Le runner est déployé dans le namespace :

```text
gitea-runner
```

État validé :

```text
StatefulSet gitea-runner : 1/1
Pod gitea-runner-0       : 2/2 Running
Redémarrages             : 0
PVC data-gitea-runner-0  : Bound, 1 Gi
```

Marqueurs fonctionnels observés :

```text
Runner registered successfully.
Docker is ready
runner: lab-games, with version: v3.5.0, with labels: [lab-node22 lab-docker], declare successfully
```

Le validateur post-PRA contrôle ces éléments automatiquement.

---

## 10. État Git et dépôts restaurés

### 10.1 Dépôt plateforme

```text
platform/infrastructure-devops
branche par défaut : main
Gitea Actions : activées
```

Après le PRA final :

```text
HEAD=88f39a93e980c13a9aef0e8e8209df22dc599b1f
gitea/main=88f39a93e980c13a9aef0e8e8209df22dc599b1f
avance=0
retard=0
```

### 10.2 Dépôt applicatif 2048

```text
Gitea : games/2048
GitHub : mouameng/games-2048
branche : main
SHA validé : 0a318110ce16fa53e01fa18c82963b7f698b1b39
```

Les branches et tags sont alignés entre Gitea et GitHub lors des contrôles préparatoires.

### 10.3 Images déployées observées pendant la validation

```text
dev  : gitea.local/games/2048@sha256:76f9ca3203fa945e751a66d161215618415e5d6ff31ea8b800d7c20de51902f3
prod : gitea.local/games/2048@sha256:12ff0073e6c68913018931ef497a137888ce365b960a00efae6317df1fb684f8
```

La différence entre dev et prod est cohérente avec la stratégie actuelle :

- dev est mis à jour automatiquement par la CI ;
- la promotion vers prod reste manuelle.

---

## 11. Validations exécutées

### 11.1 Plan

Le mode `--plan` a été exécuté sans action Kubernetes ou Docker.

Il a validé les chemins de journal sous :

```text
~/.local/share/lab/logs
```

Limite identifiée : le plan affiche principalement la reconstruction et ne décrit pas encore toute la séquence de sauvegarde, gel et destruction.

### 11.2 Prévol

Le prévol final a validé :

- alignement Git local et distant ;
- miroir GitHub ;
- dépendances hors source de vérité ;
- manifeste des sauvegardes Git ;
- accès au registre games ;
- rendu DNS ;
- hash administrateur Argo CD ;
- paire CA ;
- propreté Git ;
- absence d’action Kubernetes ou Kind.

### 11.3 Test d’annulation

Journal :

```text
~/.local/share/lab/logs/pra-cancel-v1.3.7-20261010-150103.log
```

Résultats :

```text
sync Git : OK
jeu Gitea : 20261010-150114
code : 0
clusters : inchangés
sauvegardes : conservées
```

### 11.4 PRA final

Journal :

```text
~/.local/share/lab/logs/pra-v1.3.7-final-validation-20261010-160524.log
```

Résultats :

```text
backup=20261010-160534
commit=88f39a93e980
apps=26
code PRA=0
```

Le PRA final a validé :

- sauvegardes avant confirmation ;
- reconstruction des trois clusters ;
- restauration Gitea ;
- publication des enregistrements workload ;
- synchronisation de la Root App ;
- disponibilité Whoami dev/prod ;
- disponibilité des Ingress ;
- réponses HTTP 200 ;
- ordre Certificate puis IngressRoute ;
- absence de l’ancienne erreur TLS Traefik ;
- convergence des 26 Applications ;
- runner Gitea Actions ;
- alignement Git final.

---

## 12. Fichiers ajoutés dans la v1.3.7

```text
applications/argocd/argocd-cm-health.yaml
scripts/lib/lab-paths.sh
scripts/validate-post-pra.sh
```

## 13. Fichiers principaux modifiés

```text
README-bootstrap.md
applications/gitea/certificate.yaml
applications/gitea/ingressroute.yaml
clusters/management/cluster-registration/workload-dev-sealedsecret.yaml
clusters/management/cluster-registration/workload-prod-sealedsecret.yaml
scripts/backup-git-repositories.sh
scripts/backup-gitea.sh
scripts/backup-sealed-secrets-key.sh
scripts/bootstrap-management.sh
scripts/bootstrap-platform.sh
scripts/bootstrap-workload.sh
scripts/check-external-deps.sh
scripts/check-github-mirror.sh
scripts/configure-management-dns.sh
scripts/configure-workload-registry.sh
scripts/ensure-games-pull-secret.sh
scripts/external-deps.tsv
scripts/gitea-publish.sh
scripts/restore-gitea.sh
scripts/validate-registration-candidates.sh
```

---

## 14. Procédure de reprise

### 14.1 Vérifier le dépôt local

```bash
cd ~/lab/gitea/platform/infrastructure-devops

git status --short
git rev-parse HEAD
git rev-parse gitea/main
git rev-list --count gitea/main..HEAD
git rev-list --count HEAD..gitea/main
```

### 14.2 Exécuter le prévol

```bash
scripts/bootstrap-platform.sh --preflight
```

Le prévol ne doit exécuter aucune sauvegarde, interaction, destruction ou validation post-PRA.

### 14.3 Afficher le plan

```bash
scripts/bootstrap-platform.sh --plan
```

Le mode plan est non modifiant. Son enrichissement est reporté.

### 14.4 Exécuter un PRA réel

```bash
scripts/bootstrap-platform.sh
```

Le script :

1. effectue le prévol ;
2. synchronise les dépôts Git inventoriés ;
3. crée et valide une sauvegarde fraîche de Gitea ;
4. affiche le jeu figé et le périmètre ;
5. demande la confirmation destructive ;
6. reconstruit si le choix vaut `2` ;
7. valide automatiquement l’état restauré.

### 14.5 Annuler proprement

À l’invite :

```text
Choix PRA [1=refuser (défaut), 2=détruire le périmètre affiché]
```

Saisir `1` conserve les sauvegardes et retourne le code `0`.

---

## 15. Chantiers futurs explicitement reportés

### 15.1 Journalisation automatique de `bootstrap-platform.sh`

Le bootstrap doit gérer lui-même ses journaux, au lieu de dépendre d’une enveloppe manuelle avec `tee`.

Périmètre envisagé :

- journalisation de `--plan`, `--preflight` et du PRA réel ;
- conservation de l’interactivité ;
- création automatique sous `~/.local/share/lab/logs` ;
- permissions du journal en `600` ;
- répertoire en `700` ;
- mode, horodatage, PID, commit et code retour dans le journal ;
- contrôle qu’aucun secret n’est affiché ;
- suppression ultérieure des enveloppes manuelles externes.

### 15.2 Enrichissement du mode `--plan`

Le plan actuel doit être enrichi pour refléter la séquence complète :

```text
prévol
-> sauvegardes préparatoires
-> sélection et validation du jeu Gitea
-> confirmation
-> destruction
-> reconstruction
-> restauration
-> validation post-PRA
```

### 15.3 Renommage des clusters et contextes

Renommage prévu :

```text
gitops-management -> lab-management
gitops-dev        -> lab-dev
gitops-prod       -> lab-prod
```

Contextes Kubernetes correspondants :

```text
kind-gitops-management -> kind-lab-management
kind-gitops-dev        -> kind-lab-dev
kind-gitops-prod       -> kind-lab-prod
```

Ce chantier doit couvrir :

- inventaire complet des références ;
- noms Kind, nœuds et contextes ;
- scripts ;
- inventaire `clusters/workloads.tsv` ;
- DNS et registre ;
- enregistrements Argo CD ;
- URLs d’API ;
- SealedSecrets d’enregistrement ;
- validation par PRA.

### 15.4 Factorisation des identités de clusters

Étudier une bibliothèque dédiée :

```text
scripts/lib/lab-clusters.sh
```

Elle resterait distincte de `scripts/lib/lab-paths.sh` et centraliserait :

- noms Kind ;
- contextes Kubernetes ;
- noms des clusters Argo CD ;
- éventuellement les relations entre environnement, cluster Kind et cluster Argo CD.

### 15.5 Passage du dépôt GitHub plateforme en privé

Dépôt concerné :

```text
mouameng/infrastructure-devops
```

Objectif : passer le dépôt GitHub en visibilité privée tout en conservant le fonctionnement complet du lab et du PRA.

Le chantier devra inclure :

- inventaire des accès actuellement anonymes ou implicites ;
- authentification non interactive depuis le lab ;
- adaptation du push mirror Gitea vers GitHub ;
- adaptation éventuelle de `check-github-mirror.sh` ;
- adaptation éventuelle de `backup-git-repositories.sh` ;
- stockage des jetons hors Git en mode `600` ;
- contrôle des droits minimaux ;
- vérification des branches et tags ;
- comportement du mode `--preflight` ;
- sauvegarde préparatoire avant PRA ;
- réplication des tags et fonctionnement des releases ;
- validation par PRA complet.

### 15.6 Autres chantiers déjà identifiés

Restent également dans la feuille de route générale :

- CI plateforme pour `platform/infrastructure-devops` ;
- mutualisation progressive de la CI des jeux ;
- évolution ultérieure vers une IaC plus déclarative ;
- étude d’Ansible et de Terraform selon les besoins ;
- DNS global du lab ;
- serveur PKI restaurable et rapproché des pratiques d’entreprise ;
- analyse séparée des protections contre les processus Git bloqués ;
- revue ultérieure des gardes redondantes du PRA.

---

## 16. Points de vigilance

- Ne pas supprimer les anciens répertoires avant une vérification finale d’absence de dépendance.
- Ne pas utiliser `curl -k` pour masquer une erreur TLS.
- Conserver le health check `Certificate` et les sync waves ensemble.
- Ne pas remplacer l’attente Argo CD par un délai fixe sans lecture d’état.
- Conserver la production en promotion manuelle tant que cette stratégie est souhaitée.
- Ne jamais afficher les jetons dans les journaux.
- Conserver les jetons hors Git et en mode `600`.
- Exécuter un dry-run, une inspection ou une sauvegarde avant les modifications impactantes.
- Valider toute évolution structurante du bootstrap par un PRA complet.

---

## 17. Critères de clôture v1.3.7

La v1.3.7 peut être clôturée lorsque :

- le présent document est ajouté et commité ;
- le prévol final réussit sur le commit documentaire ;
- le dépôt local et `gitea/main` sont alignés ;
- le tag annoté `v1.3.7` est créé sur le commit documentaire ;
- le tag est poussé vers Gitea ;
- la réplication GitHub du tag est vérifiée ;
- la release Gitea v1.3.7 est créée ;
- l’arbre Git final est propre.

---

## 18. Résumé de clôture

La v1.3.7 a dépassé son objectif initial de renommage des chemins locaux.

Elle apporte un PRA plus robuste et plus explicite :

- chemins locaux centralisés ;
- sauvegardes automatiques avant confirmation ;
- annulation propre ;
- validation automatique de la restauration ;
- correction déclarative de la course TLS ;
- attente bornée de la convergence CD ;
- résultat final unique et exploitable.

Le dernier PRA validé a terminé avec :

```text
backup=20261010-160534
commit=88f39a93e980c13a9aef0e8e8209df22dc599b1f
applications=26 Synced/Healthy
runner=opérationnel
TLS Gitea=conforme
code=0
```

La version est techniquement prête pour la rédaction finale, le commit documentaire, le tag annoté et la release.
