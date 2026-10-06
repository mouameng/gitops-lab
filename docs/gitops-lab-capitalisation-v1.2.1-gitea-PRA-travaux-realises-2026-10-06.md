# GitOps Lab — Capitalisation v1.2.1 : Gitea, sauvegarde et préparation du PRA

**Dernière consolidation : 6 octobre 2026, 20:05 (Europe/Paris).**
**Document source repris :** `gitops-lab-reprise-v1.2.1-gitea-PRA-en-cours-2026-10-06.md`.
**Référence antérieure :** `gitops-lab-reprise-v1.2-plus-feuille-de-route-2026-10-05.md`.
**Périmètre :** état construit et preuves disponibles au 6 octobre 2026.
**Statut de la version :** les travaux d’installation de Gitea, d’accès HTTPS, de sauvegarde automatique et de restauration isolée sont terminés et documentés. La **validation globale de la release v1.2.1 reste ouverte** tant que le PRA destructif intégré, avec restauration de l’état Gitea sur un PVC neuf, n’a pas été exécuté avec succès, documenté, tagué et publié.

> **Règle de lecture.** Ce document distingue systématiquement :
> - **Réalisé** : modification ou opération effectivement exécutée ;
> - **Validé** : résultat accompagné d’un contrôle technique ou fonctionnel ;
> - **Préparé** : fichier ou procédure disponible, mais non éprouvé dans le scénario final ;
> - **À faire** : travail nécessaire à la clôture de v1.2.1 ou reporté à une version suivante.
>
> Le document d’origine du 5 octobre est conservé intégralement en annexe. En cas de divergence, les sections 1 à 12 ci-dessous décrivent l’état le plus récent et l’annexe reste une photographie historique.

---

## 1. Objet et résultat de la séquence v1.2.1

La séquence v1.2.1 a fait évoluer le lab depuis un PRA multicluster v1.2.0 déjà validé vers une plateforme comprenant une forge Gitea autohébergée et un mécanisme de sauvegarde hors cluster.

Les résultats acquis sont les suivants :

1. Gitea est déclarée dans GitOps et installée sur `gitops-management` avec SQLite, un PVC de 2 Gi et une stratégie de déploiement `Recreate`.
2. L’accès HTTPS à `https://gitea.local/` a été mis en place avec Traefik et un certificat auto-signé géré par cert-manager.
3. Un dépôt privé `gitea_admin/gitea-test`, branche `main`, avec `README.md`, a servi de témoin fonctionnel.
4. Le périmètre de données à protéger a été inventorié : base SQLite, configuration d’instance, dépôts Git, queues et autres données sous `/data`, plus le Secret administrateur conservé hors Git.
5. Une sauvegarde manuelle cohérente a été réalisée avec Gitea arrêtée, puis contrôlée.
6. Cette archive a été restaurée sur un PVC distinct et ouverte par une seconde instance Gitea isolée ; connexion et lecture du dépôt témoin ont réussi.
7. La sauvegarde a été automatisée par `scripts/backup-gitea.sh`; une première exécution réelle a produit et validé le jeu `20261006-171417`.
8. Le futur ordre du PRA a été défini : sauvegarder avant destruction, figer le jeu sélectionné, reconstruire management, restaurer le Secret et `/data` sur un PVC neuf, puis seulement synchroniser Gitea.

**Conclusion de version :** la chaîne « installation → utilisation → sauvegarde → restauration isolée » est démontrée. La chaîne « destruction des trois clusters → reconstruction → restauration Gitea intégrée → tests applicatifs » reste le dernier critère de clôture de v1.2.1.

---

## 2. Socle hérité de v1.2.0

La v1.2.1 s’appuie sur les acquis suivants, qui n’ont pas été rejoués pour être redémontrés pendant chaque étape Gitea :

- trois clusters Kind : `gitops-management`, `gitops-dev`, `gitops-prod` ;
- Argo CD et la Root App sur management ;
- GitHub comme source GitOps d’amorçage ;
- enregistrement des clusters workload dans Argo CD ;
- déploiement et accès HTTP de Whoami sur dev et prod ;
- PRA destructif/reconstructif multicluster v1.2.0 validé et publié sous la release `v1.2.0-pra-multicluster-ok` ;
- commit documentaire de référence `067d0d575bd2c72cc3a5f5af4cf59f1777bd092a` ;
- suppression des clusters temporaires `gitops-management-test` et `gitops-workload-test` ;
- suppression de la branche distante de sauvegarde `backup/main-before-pra-multicluster` après vérification de son antériorité par rapport à `main`.

Le PRA v1.2.0 dépend encore de GitHub, de dépôts Helm, de registres d’images et potentiellement de téléchargements réalisés par le bootstrap du poste. Il ne doit pas être présenté comme un PRA hors Internet ni comme une restauration sur VM nue.

---

## 3. Historique consolidé des actions réalisées

### 3.1 État initial au 5 octobre 2026

- Metrics Server était déjà opérationnel sur dev, puis a été étendu et vérifié sur prod et management.
- Le choix de Gitea autohébergée avait été acté pour apprendre l’exploitation d’une forge locale et d’un futur runner.
- L’architecture prévue reposait sur Gitea dans `gitops-management`, pilotée par Argo CD, avec GitHub conservé comme source d’amorçage.
- Le choix de base était SQLite avec persistance sur PVC.
- L’Application `gitea` existait dans Argo CD mais restait `OutOfSync / Missing`; aucune ressource Gitea n’avait encore été créée.
- Le namespace `gitea` et le Secret manuel `gitea-admin-secret` existaient déjà.

### 3.2 Premier déploiement Gitea

1. À partir du commit `3ccaa33bc0c550ac53383d3a04b680e639ba85a0`, la Root App était `Synced/Healthy` et l’Application `gitea` attendait une synchronisation manuelle.
2. Dans l’interface Argo CD, le dialogue de synchronisation a été ouvert, puis l’action finale `SYNCHRONIZE` a été confirmée une seule fois, sans `Force` ni `Prune`.
3. L’opération s’est terminée avec le statut `Succeeded`.
4. Les contrôles ont confirmé :
   - Deployment et pod Gitea à `1/1` ;
   - PVC `gitea-shared-storage` à l’état `Bound` ;
   - Application `gitea` à l’état `Synced/Healthy` ;
   - Service `gitea-http` en ClusterIP sur le port 3000 ;
   - Service `gitea-ssh` en ClusterIP sur le port 22.
5. Un premier accès a été validé par port-forward sur `127.0.0.1:13000`.
6. La connexion avec le compte `gitea_admin` a réussi.
7. Le dépôt privé `gitea-test` a été créé avec une branche `main` et un fichier `README.md`.

### 3.3 Mise en place de l’accès HTTPS

La convention de nommage retenue est :

- management : `gitea.local`, `argocd.local`, `traefik.local` ;
- workloads : `application.environnement.local`, notamment `whoami.dev.local` et `whoami.prod.local`.

Les éléments suivants ont été ajoutés :

- `applications/gitea/ingressroute.yaml` : route Traefik vers `gitea-http:3000` ;
- `applications/gitea/certificate.yaml` : certificat `gitea-local-tls` via `selfsigned-cluster-issuer` ;
- `argocd/applications/gitea-external.yaml` : Application GitOps dédiée aux ressources d’exposition ;
- `infrastructure/gitea/values.yaml` : `ROOT_URL=https://gitea.local/`, `DOMAIN=gitea.local`, `SSH_DOMAIN=gitea.local`.

Ces changements ont été publiés au commit `dbbc798`. L’Application `gitea-external` a été créée par la Root App, puis synchronisée manuellement. Le certificat a atteint `Ready=True` et l’accès HTTPS a été vérifié.

**Limite connue :** le certificat est auto-signé. `Ready=True` démontre sa génération et son utilisation dans Kubernetes, mais pas la confiance du navigateur ou du système client. Le navigateur a signalé le certificat comme non approuvé.

### 3.4 Correction du conflit de verrouillage LevelDB

Après le changement d’URL, un nouveau pod est passé en `CrashLoopBackOff` tandis que l’ancien pod restait prêt. Le journal d’erreur indiquait :

```text
unable to lock level db at /data/queues/common: resource temporarily unavailable
```

Le diagnostic retenu est un conflit sur la queue LevelDB provoqué par la coexistence de deux pods sur le même PVC pendant un déploiement `RollingUpdate`. Il ne s’agit pas d’une preuve de verrouillage de la base SQLite.

La correction appliquée dans `infrastructure/gitea/values.yaml` est :

```yaml
strategy:
  type: Recreate
  rollingUpdate: null
```

Le rendu Helm a confirmé `type: Recreate` sans bloc `rollingUpdate`. Le correctif a été publié au commit `d37b210`, puis synchronisé manuellement. La stratégie active est devenue `Recreate`; l’Application est revenue `Synced/Healthy`, le pod était prêt et le PVC inchangé.

**Décision d’exploitation :** la courte interruption liée à `Recreate` est acceptée pour ce lab mono-réplique SQLite. Cette décision est fondée sur le conflit observé localement ; elle ne doit pas être présentée comme une recommandation générale explicitement imposée par le chart officiel.

### 3.5 Mesures de ressources

Mesure ponctuelle après installation de Gitea :

| Périmètre | CPU | Mémoire |
|---|---:|---:|
| Pod Gitea | 1 mCPU | 90 MiB |
| Nœud management après installation | 130 mCPU | 3 111 MiB |
| Nœud management avant Gitea, photographie antérieure | 158 mCPU | 2 977 MiB |

Ces valeurs sont des instantanés et non des pics ou des moyennes. La variation globale du nœud ne peut pas être attribuée intégralement à Gitea.

### 3.6 Inventaire des données et des secrets

Le PVC `gitea-shared-storage` est monté sous `/data`. Les éléments importants identifiés sont notamment :

- `/data/gitea.db` : base SQLite ;
- `/data/gitea/conf/app.ini` : configuration d’instance, incluant des valeurs sensibles ;
- `/data/git/gitea-repositories` : dépôts Git ;
- `/data/queues` : files internes ;
- les répertoires d’attachments, avatars, actions, packages et SSH.

Secrets recensés :

- `gitea`, `gitea-init`, `gitea-inline-config` générés par le chart ;
- `gitea-admin-secret` créé manuellement et conservé hors Git ;
- `gitea-local-tls` généré via cert-manager.

Le fichier `app.ini` restauré reste essentiel : le Secret Helm `gitea-inline-config` ne doit pas être considéré comme capable de recréer à lui seul tous les secrets internes d’une instance existante.

### 3.7 Sauvegarde manuelle cohérente

La destination hors dépôt utilisée est :

```text
$HOME/.local/share/gitops-lab/backups/gitea
```

Le répertoire est protégé en mode 700 et les archives/exports sensibles en mode 600.

La première sauvegarde manuelle a suivi cette séquence :

1. export du Secret administrateur hors Git ;
2. arrêt contrôlé du Deployment Gitea à zéro réplica ;
3. création d’un pod lecteur temporaire montant le PVC en lecture seule ;
4. archivage cohérent de `/data` ;
5. contrôle de présence de la base, de la configuration et des dépôts ;
6. contrôle SQLite ;
7. suppression du pod lecteur ;
8. redémarrage de Gitea ;
9. vérification fonctionnelle du dépôt témoin.

Preuves consignées :

- export : `gitea-admin-secret-20261006-105140.json` ;
- archive : `gitea-data-20261006-110331.tar.gz` ;
- SHA-256 de l’archive : `21e12ff12a62f15b724b40dadf1b4c43c7eb244b0b5459f97f1fa1029b1df71a` ;
- SHA-256 historique de l’export du Secret : `0473b9537040b3eb2d5914cc9e238ea588a032beeb0b2477e9e20c07d3274187` ;
- `gitea.db-wal` et `gitea.db-shm` absents après l’arrêt ;
- `SQLite quick_check: ok` ;
- retour de Gitea et accès au dépôt confirmés.

Ces noms et empreintes sont des preuves historiques. Ils ne doivent pas être codés comme constantes dans le bootstrap.

### 3.8 Restauration isolée éprouvée

Une restauration fonctionnelle indépendante a été effectuée :

1. création du PVC distinct `gitea-restore-test` de 2 Gi ;
2. provisionnement par un pod temporaire, nécessaire avec `WaitForFirstConsumer` ;
3. extraction de l’archive sur ce PVC ;
4. comparaison des empreintes de la base et de `app.ini` avec l’archive ;
5. contrôle Git : résolution de `HEAD` et présence du `README.md` ;
6. rendu du chart avec `persistence.create=false` et `persistence.claimName=gitea-restore-test` ;
7. lancement d’une release isolée `gitea-restore-check` ;
8. accès local sur `http://127.0.0.1:13001/` ;
9. connexion réussie et lecture du dépôt témoin ;
10. désinstallation de la release de test.

Le PVC `gitea-restore-test` était encore conservé au dernier contrôle, tandis qu’aucun pod ni service de test ne restait actif.

**Portée de la preuve :** cette restauration valide l’archive manuelle antérieure et la compatibilité de la version actuelle de Gitea avec les données restaurées. Elle ne valide pas encore l’adoption du PVC principal prérempli pendant le PRA intégré.

### 3.9 Automatisation de la sauvegarde

Les fichiers suivants ont été publiés au commit `b40bd85` (`feat(gitea): add validated off-cluster backup`) :

- `scripts/backup-gitea.sh` ;
- `scripts/manifests/gitea-backup-reader.yaml`.

Le pod lecteur utilise l’image `docker.gitea.com/gitea:1.27.0-rootless`, l’UID/GID 1000, monte `gitea-shared-storage` en lecture seule sur `/data` et reste temporaire.

Chaque jeu publié suit cette structure :

```text
AAAAMMJJ-HHMMSS/
├── data.tar.gz
├── admin-secret.json
└── manifest.json
```

`manifest.json` contient la version de format, l’horodatage ISO 8601 avec fuseau et les empreintes SHA-256. Les jeux en cours sont créés sous un nom temporaire `.gitea-backup-*`, puis publiés atomiquement après validation.

Modes testés :

```bash
bash scripts/backup-gitea.sh --list
bash scripts/backup-gitea.sh --validate NOM_DU_JEU
bash scripts/backup-gitea.sh --latest
bash scripts/backup-gitea.sh --backup-preflight
bash scripts/backup-gitea.sh --backup-plan
bash scripts/backup-gitea.sh --backup
```

Comportements validés :

- tri par nom de dossier horodaté, et non par date de modification ;
- validation du jeu le plus récent ;
- refus de revenir silencieusement à un jeu plus ancien si le plus récent est incomplet ;
- exclusion des anciens fichiers à plat de la sélection automatique ;
- exclusion des répertoires temporaires `.gitea-backup-*` ;
- vérification des empreintes des deux fichiers protégés ;
- validation gzip/tar ;
- présence de `gitea.db`, `app.ini` et du répertoire des dépôts ;
- contrôle de structure de l’export du Secret ;
- armement du `trap` avant l’arrêt de Gitea ;
- suppression du lecteur et tentative de redémarrage sur sortie normale, `INT` ou `TERM`.

Un défaut Bash de portée de variable, qui faisait afficher `[SELECT] admin-secret.json`, a été corrigé en déclarant `name` local dès l’entrée de la fonction de validation. Le test a ensuite sélectionné correctement `20261006-120100` parmi deux jeux factices.

Première sauvegarde automatisée réelle :

- jeu publié : `20261006-171417` ;
- validation du jeu temporaire réussie ;
- code retour 0 ;
- `--latest` a resélectionné et revalidé `20261006-171417` ;
- Deployment Gitea revenu à `1/1` ;
- interface et dépôt accessibles ;
- aucun pod lecteur ni répertoire temporaire résiduel observé.

**Limite :** le jeu automatique `20261006-171417` a été contrôlé par le script, mais n’a pas été restauré fonctionnellement. Le chemin d’échec après arrêt réel de Gitea n’a pas été provoqué ; un `kill -9` ou une indisponibilité de Kubernetes peut dépasser ce que les traps peuvent réparer.

---

## 4. Architecture réalisée à la fin des travaux documentés

```text
GitHub : dépôt gitops-lab, source d’amorçage
  └─ Root App Argo CD sur gitops-management
      ├─ applications d’infrastructure et workloads
      ├─ Application gitea
      │   └─ chart Gitea 12.7.0 / application 1.27.0
      │       ├─ mono-réplique
      │       ├─ stratégie Recreate
      │       ├─ SQLite
      │       └─ PVC gitea-shared-storage, standard, 2 Gi
      └─ Application gitea-external
          ├─ IngressRoute Traefik pour gitea.local
          └─ Certificate gitea-local-tls

Poste WSL, hors dépôt Git
  └─ $HOME/.local/share/gitops-lab/backups/gitea
      ├─ jeux de sauvegarde datés
      └─ Secret administrateur exporté
```

### 4.1 Caractéristiques du stockage

- StorageClass : `standard` ;
- provisioner : `rancher.io/local-path` ;
- mode : `WaitForFirstConsumer` ;
- ReclaimPolicy : `Delete` ;
- capacité demandée : 2 Gi ;
- accès : RWO ;
- extension de volume non disponible dans l’observation initiale.

Le PVC ne constitue pas une sauvegarde : il disparaît avec le cluster Kind. L’annotation Helm `helm.sh/resource-policy: keep` ne garantit pas la survie à `kind delete cluster`.

### 4.2 Décisions de conception

| Sujet | Décision v1.2.1 | Motif |
|---|---|---|
| Source d’amorçage | GitHub | Évite que Gitea soit nécessaire pour déployer Gitea. |
| Forge | Gitea autohébergée | Apprentissage d’exploitation d’une forge locale avec empreinte raisonnable. |
| Base | SQLite | Choix pédagogique et simplicité du jalon ; restauration spécifique testée. |
| Persistance | PVC local-path 2 Gi | Adapté au lab, sans prétention de haute disponibilité. |
| Déploiement | Un réplica, `Recreate` | Évite le conflit LevelDB constaté sur un PVC partagé. |
| Synchronisation | Manuelle pour `gitea` et `gitea-external` | Permet d’imposer l’ordre de restauration avant démarrage. |
| Sauvegarde | Archive cohérente de `/data` avec Gitea arrêtée + Secret hors Git | Réduit le risque d’incohérence SQLite et protège les données sensibles. |
| Destination | WSL hors dépôt | Survit à la destruction Kind, mais pas à la perte du poste. |
| Restauration v1.2.1 | Pod temporaire piloté par script | Le transfert `kubectl exec -i` depuis WSL a déjà été éprouvé. |
| Runner | Séparé et reporté | Ne pas coupler l’exécution CI à la forge avant d’avoir défini l’isolation. |

### 4.3 Configuration effective de Gitea

L’Application `argocd/applications/gitea.yaml` utilise deux sources :

- le chart Helm `12.7.0` depuis `https://dl.gitea.io/charts` ;
- les valeurs du dépôt GitHub via `$values/infrastructure/gitea/values.yaml`, avec `ref: values` et sans `path` sur la source de valeurs.

La destination est `https://kubernetes.default.svc`, namespace `gitea`. La configuration active comprend :

- application Gitea `1.27.0` ;
- désactivation de `valkey-cluster`, `valkey`, `postgresql` et `postgresql-ha` ;
- `persistence.enabled: true`, StorageClass `standard`, taille 2 Gi ;
- `gitea.admin.existingSecret: gitea-admin-secret` ;
- `database.DB_TYPE: sqlite3` ;
- session et cache en mémoire ;
- queue de type `level` ;
- mode d’administration `initialOnlyNoReset` ;
- un réplica et stratégie `Recreate` ;
- `ROOT_URL`, `DOMAIN` et `SSH_DOMAIN` alignés sur `gitea.local`.

Le chart et ses images restent des dépendances externes. Les mots de passe d’exemple des valeurs par défaut du chart n’ont pas été utilisés. L’Application `gitea` n’a pas de `syncPolicy.automated`, choix conservé pour empêcher un démarrage avant restauration pendant le PRA.

Lors du test de restauration isolé, les scripts d’initialisation du chart ont aussi été examinés : la structure de répertoires est préparée avec l’UID/GID attendu, la configuration existante peut être éditée, une migration peut être exécutée, et le mode `initialOnlyNoReset` ne réinitialise pas le mot de passe d’un compte administrateur déjà présent. La preuve fonctionnelle vaut pour la version fixée ; ces comportements doivent être revérifiés avant toute montée de version.

---

## 5. Livrables et traçabilité Git

### 5.1 Fichiers publiés

| Fichier | Rôle | État |
|---|---|---|
| `argocd/applications/gitea.yaml` | Application Helm multi-source Gitea | Publié et utilisé |
| `infrastructure/gitea/values.yaml` | SQLite, persistance 2 Gi, URL, stratégie Recreate | Publié et utilisé |
| `applications/gitea/certificate.yaml` | Certificat local Gitea | Publié et validé `Ready=True` |
| `applications/gitea/ingressroute.yaml` | Exposition Traefik de Gitea | Publié et accès vérifié |
| `argocd/applications/gitea-external.yaml` | Application des ressources externes | Publié et synchronisé |
| `scripts/backup-gitea.sh` | Sauvegarde et validation hors cluster | Publié et exécuté réellement |
| `scripts/manifests/gitea-backup-reader.yaml` | Pod lecteur temporaire du PVC | Publié et exécuté réellement |

### 5.2 Commits de référence

| Commit | Contenu documenté |
|---|---|
| `3ccaa33bc0c550ac53383d3a04b680e639ba85a0` | Déclaration GitOps initiale de Gitea et valeurs SQLite/PVC |
| `dbbc798` | Accès `gitea.local`, certificat et ressources externes |
| `d37b210` | Passage du Deployment à la stratégie `Recreate` |
| `b40bd85` | Sauvegarde hors cluster automatisée et validée |

Le dernier commit publié explicitement confirmé dans les traces disponibles est `b40bd85`.

### 5.3 Fichiers préparés mais non publiés au dernier contrôle

- `scripts/manifests/gitea-restore-pvc.yaml` ;
- `scripts/manifests/gitea-restore-pod.yaml`.

Ils étaient non suivis dans `git status`. Leur dry-run serveur a réussi sur le cluster existant, mais ils ne doivent pas être appliqués sur l’instance active car ils ciblent le nom du PVC principal.

### 5.4 Script non confirmé

`scripts/restore-gitea.sh` n’était pas confirmé présent. Une tentative de collage de son contenu directement dans Bash a produit `Usage : -bash --preflight`, puis `logout` et un retour dans PowerShell. Aucune modification Kubernetes ni destruction n’a été attestée pendant cet incident.

La première vérification non destructive à réaliser est :

```bash
cd ~/lab/gitops-lab
git status --short
test -f scripts/restore-gitea.sh \
  && echo 'restore-gitea.sh présent' \
  || echo 'restore-gitea.sh absent'
bash scripts/backup-gitea.sh --latest
```

Ne jamais coller directement le contenu d’un script comportant `exit` dans un shell interactif. Écrire le fichier avec un éditeur ou une redirection contrôlée, l’inspecter avec `sed`, puis exécuter `bash -n` avant tout mode actif.

### 5.5 État du bootstrap

`scripts/bootstrap-platform.sh` était revenu propre avant le commit de sauvegarde. Les chemins et empreintes datés ajoutés provisoirement en avaient été retirés. À la dernière preuve disponible, il ne lançait pas encore `scripts/backup-gitea.sh`, ne restaurait ni `gitea-admin-secret` ni `/data`, et terminait par les contrôles Whoami existants. Son évolution appartient donc aux actions de clôture décrites en section 8, et non aux travaux déjà validés.

---

## 6. Matrice de validation v1.2.1

| Capacité / critère | Réalisé | Validé | Preuve ou observation | Reste à faire |
|---|:---:|:---:|---|---|
| Gitea déclarée par GitOps | Oui | Oui | Application créée et synchronisée | — |
| Gitea mono-pod SQLite sur PVC | Oui | Oui | Pod `1/1`, PVC `Bound`, `Synced/Healthy` | — |
| Accès initial | Oui | Oui | Port-forward et connexion admin | — |
| Accès HTTPS `gitea.local` | Oui | Oui | Route, certificat prêt, accès et dépôt consultés | Installer la confiance client si souhaité |
| Dépôt témoin | Oui | Oui | `gitea_admin/gitea-test`, `main`, `README.md` | Conserver comme preuve PRA |
| Correctif `Recreate` | Oui | Oui | Rendu Helm et état actif contrôlés | Recontrôler après futur upgrade |
| Inventaire des données | Oui | Oui | Base, configuration, dépôts, queues et secrets identifiés | Maintenir l’inventaire selon les fonctionnalités activées |
| Sauvegarde manuelle cohérente | Oui | Oui | Archive, empreinte, `quick_check`, redémarrage | — |
| Restauration sur PVC distinct | Oui | Oui | Seconde instance, connexion et README | — |
| Sauvegarde automatisée | Oui | Oui | Jeu `20261006-171417`, code 0, service revenu | Restaurer ce jeu lors du PRA final |
| Gestion d’un échec après arrêt réel | Partiel | Non | Traps conçus, scénario non provoqué | Ajouter un test contrôlé et une procédure manuelle |
| Script de restauration final | Non confirmé | Non | Fichier absent ou état inconnu au dernier contrôle | Écrire, relire, tester et publier |
| Intégration au bootstrap | Non | Non | Bootstrap encore sans sauvegarde/restauration Gitea | Implémenter le séquencement |
| Adoption du PVC principal prérempli | Préparé | Non | Manifeste et dry-run seulement | Tester après reconstruction |
| PRA destructif v1.2.1 | Non | Non | Aucun nouvel exercice destructif attesté | Exécuter et documenter |
| Tag et release v1.2.1 | Non | Non | Aucun tag confirmé | Créer seulement après recette complète |

Cette matrice constitue la référence de clôture. Une ligne marquée « Non » ne doit pas être convertie en « Oui » à partir d’un dry-run, d’un rendu Helm ou d’une intention.

---

## 7. Procédures de référence issues des travaux terminés

### 7.1 Vérification quotidienne non destructive

```bash
cd ~/lab/gitops-lab
git status --short
bash scripts/backup-gitea.sh --list
bash scripts/backup-gitea.sh --latest
kubectl --context kind-gitops-management -n gitea get deployment,pods,pvc
```

Objectifs : confirmer l’état Git, l’existence d’un jeu valide et la disponibilité de Gitea sans déclencher de modification.

### 7.2 Sauvegarde planifiée avant PRA

1. Exécuter le prévol de sauvegarde.
2. Vérifier le contexte Kubernetes et l’état de Gitea.
3. Lancer `--backup` avant tout `kind delete cluster`.
4. Interrompre le PRA si la sauvegarde échoue.
5. Noter et figer le nom exact du jeu publié.
6. Relancer `--validate NOM_DU_JEU` ou `--latest` pour confirmer le jeu.
7. Vérifier que Gitea est revenue à `1/1` et que le dépôt témoin est lisible.
8. Ne plus resélectionner implicitement `--latest` après la destruction : le PRA doit restaurer le jeu figé.

### 7.3 Principes de restauration validés en environnement isolé

- restaurer le Secret administrateur sans métadonnées provenant de l’ancien cluster ;
- créer le PVC et laisser un pod consommateur déclencher le provisionnement avec `WaitForFirstConsumer` ;
- refuser un volume cible non vide ;
- transférer l’archive depuis le stockage hors cluster ;
- vérifier les fichiers critiques et leurs empreintes ;
- supprimer le pod de restauration, mais conserver le PVC ;
- synchroniser Gitea seulement après la restauration des données ;
- vérifier la stratégie `Recreate` ;
- réaliser les tests fonctionnels après le démarrage.

Ces principes sont validés par la restauration isolée. Leur automatisation et leur exécution dans le PRA destructif complet restent à terminer.

### 7.4 Tests fonctionnels minimaux après restauration

- Application `gitea` : `Synced/Healthy` ;
- Application `gitea-external` : `Synced/Healthy` ;
- PVC principal : `Bound` ;
- pod Gitea : `Ready` ;
- certificat : `Ready=True` ;
- accès à `https://gitea.local/` ;
- connexion `gitea_admin` ;
- présence du dépôt privé `gitea-test` ;
- branche `main` visible ;
- `README.md` lisible ;
- absence de pod de sauvegarde/restauration temporaire ;
- Whoami dev et prod toujours accessibles ;
- trois clusters enregistrés et sains.

Aucune valeur de Secret, contenu complet de `app.ini` ou archive sensible ne doit apparaître dans le journal de recette.

---

## 8. Séquence restante pour clôturer v1.2.1

Les étapes ci-dessous sont les seules actions encore classées dans v1.2.1.

### 8.1 Finaliser le script de restauration

Le script doit au minimum :

- proposer un mode de prévol strictement non destructif ;
- accepter le nom explicite d’un jeu de sauvegarde ;
- vérifier les empreintes et la structure avant création de ressources ;
- vérifier le contexte `kind-gitops-management` ;
- refuser de restaurer si Gitea ou le PVC principal est déjà actif ;
- recréer le namespace si nécessaire ;
- restaurer le Secret sans anciennes métadonnées Kubernetes ;
- créer le PVC principal ;
- créer et attendre le pod temporaire ;
- refuser un volume non vide ;
- transférer l’archive ;
- vérifier les fichiers requis ;
- supprimer et attendre la disparition du pod ;
- conserver le PVC ;
- ne jamais afficher de donnée sensible.

Le script doit être contrôlé par `bash -n`, relu, testé d’abord sur une cible isolée, puis publié.

### 8.2 Intégrer sauvegarde et restauration au bootstrap

Le bootstrap doit :

1. conserver un `--preflight` non destructif ;
2. afficher les jeux disponibles et valider les prérequis ;
3. après confirmation du scénario destructif et avant la première suppression Kind, créer une sauvegarde fraîche si management est actif ;
4. arrêter la procédure si la sauvegarde échoue ;
5. figer le jeu retenu ;
6. reconstruire les clusters ;
7. restaurer Secret et `/data` avant le premier Sync de Gitea ;
8. synchroniser dans un ordre contrôlé Root App, ressources externes et Gitea ;
9. exécuter les contrôles multicluster et Gitea ;
10. produire un récapitulatif de recette sans secret.

### 8.3 Tester l’adoption du PVC restauré

Le test doit démontrer que le PVC `gitea-shared-storage`, créé et rempli avant le chart, est réutilisé sans suppression ni remplacement. Il faut comparer UID du PVC/PV, événements, contenu et état avant/après synchronisation.

### 8.4 Exécuter le PRA destructif complet

Critères de succès :

- sauvegarde fraîche créée avant destruction ;
- trois clusters détruits puis reconstruits ;
- Root App et enregistrements des workloads fonctionnels ;
- Whoami dev/prod et leurs ingress accessibles ;
- Secret Gitea restauré hors Git ;
- archive restaurée sur un PVC neuf ;
- Gitea et son exposition `Synced/Healthy` ;
- connexion et dépôt témoin retrouvés ;
- jeu exact restauré consigné ;
- limites Internet et certificat consignées ;
- aucun résidu temporaire ;
- documentation mise à jour ;
- tag et release créés seulement après revue des preuves.

---

## 9. Incidents, enseignements et garde-fous

### 9.1 Enseignements techniques

1. Ouvrir le dialogue Sync Argo CD ne déclenche pas l’opération ; il faut confirmer l’action et observer `status.operationState`.
2. Une application mono-réplique avec état partagé peut être incompatible avec un RollingUpdate faisant coexister deux pods.
3. Un PVC local-path ne remplace jamais une sauvegarde hors cluster.
4. L’arrêt cohérent de Gitea simplifie la sauvegarde SQLite et évite de dépendre d’un traitement implicite des fichiers WAL/SHM.
5. Vérifier une archive n’est pas équivalent à restaurer l’application ; la restauration isolée apporte la preuve fonctionnelle manquante.
6. Un Secret d’administration externe au chart doit être explicitement inclus dans le PRA.
7. La sélection automatique d’une sauvegarde doit refuser les jeux incomplets et ne jamais revenir silencieusement à une archive plus ancienne.
8. GitHub doit rester indépendant de Gitea tant que Gitea fait partie des éléments à reconstruire.
9. Les commandes de récupération doivent être testées sur une cible isolée avant toute exécution destructive.
10. Un certificat Kubernetes prêt n’implique pas une chaîne de confiance installée sur le poste client.

### 9.2 Garde-fous permanents

- Ne jamais publier dans Git un mot de passe, un export de Secret, `app.ini`, une archive de `/data` ou un rendu Helm complet contenant des Secrets.
- Ne jamais lancer le PRA destructif si la sauvegarde fraîche n’est pas validée.
- Ne jamais restaurer sur le PVC actif pour « tester » le script.
- Ne jamais laisser l’auto-sync démarrer Gitea avant la restauration du PVC.
- Ne jamais supposer qu’un dry-run prouve le comportement d’adoption d’un PVC prérempli.
- Ne jamais considérer le seul cache Docker du portable comme une preuve de fonctionnement hors Internet.
- Ne jamais supprimer `gitea-restore-test` sans vérifier qu’il n’est plus nécessaire au diagnostic ; ne jamais confondre ce PVC avec le PVC principal.

---

## 10. Écarts connus et risques résiduels

| Risque / limite | Impact | Traitement |
|---|---|---|
| Sauvegarde stockée uniquement sur le poste WSL | Perte possible avec le poste | À durcir en v1.2.2 |
| Jeu automatique non encore restauré | Validation partielle de l’automatisation | Le restaurer lors du PRA final v1.2.1 |
| Échec après arrêt réel non testé | Gitea pourrait rester arrêtée | Ajouter test contrôlé et runbook manuel |
| Script de restauration non confirmé | PRA non automatisable de bout en bout | Finaliser avant destruction |
| Adoption du PVC non prouvée | Risque de conflit ou recréation | Test obligatoire avant clôture |
| Certificat auto-signé non approuvé | Alerte navigateur | Documenter ou distribuer la CA en v1.2.2 |
| Dépendances externes | PRA impossible sans certaines ressources réseau | Sujet v1.4/v1.5 selon priorisation |
| SQLite mono-réplique | Interruption pendant rollout/sauvegarde | Accepté pour le lab ; conserver `Recreate` |
| Absence de runner | Pas encore de CI locale | Reporté à v1.2.3 |
| Pas de politique de rétention | Croissance non maîtrisée | Définir en v1.2.2 |

---

## 11. Feuille de route révisée après v1.2.1

Les numéros ci-dessous sont une proposition de découpage. Ils ne doivent devenir des versions officielles qu’après validation de leur périmètre.

### v1.2.1 — Clôture du PRA Gitea avec état restauré

**Déjà terminé :** installation, accès HTTPS, dépôt témoin, correctif Recreate, sauvegarde manuelle, restauration isolée, sauvegarde automatisée réelle.

**À terminer :** script de restauration, intégration au bootstrap, adoption du PVC, PRA destructif complet, documentation de recette, tag et release.

Le périmètre autrefois proposé pour v1.2.2 — « PRA avec état Gitea restauré » — est désormais intégré à v1.2.1 et ne doit plus être présenté comme un jalon séparé.

### v1.2.2 — Durcissement opérationnel sauvegarde, secrets et TLS

Actions proposées :

- définir fréquence, rétention et purge sûre des jeux ;
- ajouter un contrôle SQLite automatique sur les nouvelles archives ou sur une copie extraite ;
- tester le chemin d’échec après arrêt de Gitea et documenter la reprise manuelle ;
- copier les sauvegardes sur un support indépendant du poste WSL ;
- chiffrer ou protéger les exports sensibles au repos ;
- vérifier périodiquement une restauration complète ;
- décider si le pod temporaire reste la solution ou si un Job apporte un gain opérationnel ;
- distribuer la confiance de la CA locale ou formaliser l’acceptation de l’avertissement ;
- nettoyer le PVC `gitea-restore-test` après conservation des preuves nécessaires.

### v1.2.3 — Runner Gitea et premier pipeline 2048

Actions proposées :

- installer un Gitea Runner distinct de la forge ;
- choisir son mode d’isolation et limiter l’accès au moteur Docker ;
- documenter son enregistrement, ses secrets et sa restauration ;
- utiliser 2048 comme premier démonstrateur ;
- modifier visuellement l’application, tester et construire dans Gitea Actions ;
- publier une image immuable et versionnée ;
- mettre à jour le dépôt GitOps sur GitHub ;
- déployer d’abord sur dev, puis promouvoir exactement la même image en prod ;
- tester la réinscription ou restauration du runner après reconstruction.

### v1.3 — Portefeuille d’applications et PRA de chaîne CI/CD

Actions proposées :

- déployer 2048, Snake et Hextris sur dev et prod, un réplica par jeu et environnement visé ;
- conserver Whoami comme témoin historique ;
- vérifier licences, provenance des images, ingress et ressources ;
- généraliser la promotion contrôlée quand elle apporte une valeur pédagogique ;
- rejouer un PRA couvrant forge, runner, images accessibles, pipelines et applications ;
- formaliser les preuves de promotion dev vers prod.

### v1.4 — Registre Harbor

Actions proposées :

- étudier et déployer un registre privé ;
- définir authentification, stockage, sauvegarde et restauration ;
- migrer progressivement les images applicatives ;
- qualifier l’usage d’artefacts OCI si pertinent ;
- traiter la dépendance circulaire d’un Harbor hébergé sur management et nécessaire à sa propre reconstruction.

### v1.5 et au-delà — Portabilité et réduction des dépendances

Actions proposées :

- inventorier toutes les dépendances réseau : images Kind/Kubernetes, images applicatives, charts, outils et dépôts ;
- définir un scénario mesurable de PRA à Internet réduit, distinct d’un véritable air-gap ;
- précharger ou répliquer les artefacts requis ;
- préparer un kit de restauration sur VM nue ;
- externaliser les prérequis sensibles : manifeste Argo CD vérifié, clé Sealed Secrets et sauvegardes ;
- rendre chemins et paramètres réseau portables ;
- réévaluer Vault, Terraform, Ansible, ApplicationSet et la réorganisation Argo CD seulement après stabilisation des jalons précédents.

---

## 12. Journal documentaire

| Date | Évolution |
|---|---|
| 5 octobre 2026 | Photographie après v1.2.0 : Metrics Server, choix de Gitea, préparation GitOps et feuille de route initiale. |
| 6 octobre 2026, première consolidation | Ajout du déploiement Gitea, de l’accès, du correctif Recreate, de la sauvegarde manuelle, de la restauration isolée et de l’automatisation. |
| 6 octobre 2026, présente consolidation | Réorganisation en document de référence v1.2.1, séparation explicite réalisé/validé/préparé/à faire, matrice de validation, procédures, risques et nouvelle feuille de route. |

---

# Annexe A — Document original du 5 octobre 2026, conservé intégralement

> **Photographie historique, non procédure de reprise actuelle.** Les états et jalons décrits ci-dessous étaient vrais ou proposés à la date du document original ; consulter d’abord les sections actualisées ci-dessus.

# GitOps Lab : reprise après v1.2 et feuille de route

**État consigné : fin de la séance du 5 octobre 2026.**
**Nature : document de reprise et propositions de jalons, pas compte rendu de validation des futures versions.**
**Référence historique :** `docs/gitops-lab-capitalisation-PRA-multicluster-PRA-valide-2026-10-05.md`, publié dans `gitops-lab` à la release `v1.2.0-pra-multicluster-ok`. Le présent document ne remplace pas cette capitalisation.

## 1. Synthèse immédiate

- La v1.2 a validé un PRA destructif et reconstructif sur trois clusters Kind : `gitops-management`, `gitops-dev`, `gitops-prod`. Le dépôt GitOps reste sur GitHub ; Argo CD est installé sur management et la Root App réconcilie le dépôt. Les workloads et l'accès HTTP Whoami dev/prod ont été vérifiés pendant le PRA.
- Après la release v1.2, Metrics Server a été étendu de dev à prod et management. Les trois clusters fournissent désormais `kubectl top` dans les observations de cette séance.
- Un premier jalon Gitea est **préparé mais non déployé** : l'Application Argo CD existe sur management, sans synchronisation automatique, et ses ressources cibles sont `OutOfSync / Missing`. Aucun Deployment ni PVC Gitea n'existait au dernier contrôle. Ne pas interpréter cela comme une panne du chart.
- Le dernier contrôle d'opération affichait `operation= phase= message=` vide : aucun Sync Gitea n'était enregistré. Nous nous sommes arrêtés **avant le premier Sync effectif**. Ne pas répéter un Sync à l'aveugle ; examiner le dialogue Argo CD, confirmer l'action, puis observer `status.operationState`.
- Le namespace `gitea` et le Secret `gitea-admin-secret` ont été créés manuellement sur management. Le Secret n'est ni dans Git ni encore couvert par une sauvegarde/restauration PRA. Ne jamais afficher sa valeur ni la copier dans ce document.

## 2. Architecture et frontières de responsabilité

```text
GitHub : gitops-lab, source d'amorçage du PRA et de la Root App
  -> bootstrap des trois clusters Kind
  -> Argo CD sur management
  -> enregistrements des clusters workload renouvelés et publiés
  -> Root App, Applications infrastructure et workloads
  -> Gitea sur management (Application déclarée, Sync manuel encore à faire)
  -> futur Gitea Runner et pipelines des jeux
```

- GitHub reste la source GitOps et la dépendance d'amorçage. **Ne pas déplacer la Root App vers Gitea** pendant ce chantier : Gitea ne doit pas être nécessaire pour déployer Gitea.
- Gitea est destinée à être administrée comme forge locale et à héberger le code des applications et leur CI ; son installation sur management n'implique pas que les données de sa base ou de ses dépôts soient automatiquement restaurées.
- Les trois clusters Kind partagent la même machine physique. Les valeurs « allocatable » de chaque nœud ne sont pas trois réserves matérielles indépendantes.
- Le PRA v1.2 dépend encore d'Internet et d'artefacts distants : dépôt GitHub, dépôts Helm, registres d'images et potentiellement téléchargements du bootstrap du poste. Le clone Git local n'est pas une source automatiquement accessible à Argo CD dans le cluster.
- La perspective « VM nue » est un **objectif ultérieur**, pas une propriété validée de `bootstrap-platform.sh` aujourd'hui. Manifeste Argo CD vérifié, sauvegarde de clé Sealed Secrets et autres prérequis hors dépôt doivent être inventoriés et transportés/restaurés.

## 3. Historique vérifié depuis la release v1.2

### 3.1 Release et nettoyage

- Release GitHub `v1.2.0-pra-multicluster-ok` publiée sur le commit documentaire `067d0d575bd2c72cc3a5f5af4cf59f1777bd092a`.
- Les clusters d'essai `gitops-management-test` et `gitops-workload-test` ont été supprimés. Le dernier `kind get clusters` ne montrait que management, dev et prod.
- La branche distante de sauvegarde `backup/main-before-pra-multicluster`, pointant vers `530b109…`, a été supprimée après vérification qu'elle était ancêtre de `main`. Le tag et la release v1.2 sont restés en place.

### 3.2 Metrics Server sur les trois clusters

- Avant correction, `metrics-server` ciblait uniquement `workload-dev` ; `kubectl top` échouait sur management et prod. Ce n'était pas une preuve d'un besoin de ConfigMap multicluster.
- Application `metrics-server-prod` publiée au commit `3d9781a`, puis Root App rafraîchie. Prod : Application `Synced/Healthy`, API Metrics `Available=True`, `kubectl top` fonctionnel.
- Application `metrics-server-management` publiée au commit `2e69ea1`, puis hard refresh de la Root App effectué dans l'interface. Management : Application `Synced/Healthy`, pod prêt, API Metrics `Available=True`, `kubectl top` fonctionnel.
- Photographie **instantanée avant les jeux**, et non historique ni pic :

| Cluster | CPU `top nodes` | Mémoire `top nodes` | Requests CPU | Requests mémoire |
| --- | ---: | ---: | ---: | ---: |
| Management | 158m | 2 977 Mi | 1 050m | 490 Mi |
| Dev | 105m | 1 492 Mi | 1 150m | 580 Mi |
| Prod | 116m | 1 425 Mi | 1 150m | 580 Mi |

- Chaque nœud annonçait 4 CPU et `12249708Ki` de mémoire allouable. L'hôte affichait 11 Gi de RAM, 7,4 Gi disponibles et 3 Gi de swap quasi inutilisés lors de la mesure. `df -h .` affichait 944 G disponibles ; Docker annonçait 7,329 GB de volumes actifs, à **ne pas nettoyer automatiquement**. Refaire les mesures avant dimensionnement définitif.
- `kubectl top` est adapté aux relevés ponctuels CPU/mémoire ; il ne remplace pas un stockage historique ou des alertes. Les mesures des nœuds incluent plus que les seuls pods listés.

### 3.3 Choix de Gitea et de sa base

- Alternatives débattues : GitLab.com évite la charge serveur locale mais laisse surtout un rôle d'utilisateur de plateforme et dépend d'Internet pour la CI ; GitLab Self-Managed enseignerait l'administration recherchée, mais sa configuration de référence est lourde pour ce portable. Gitea autohébergé a été retenu pour apprendre l'exploitation d'une forge et de son runner. **Gitea Actions n'est pas GitLab CI** : compétences transférables, mais syntaxe et procédures différentes.
- Hébergement choisi pour le premier jalon : Gitea sur `gitops-management`, gérée par Argo CD, avec GitHub conservé comme source d'amorçage. Cela prépare un futur PRA plus ambitieux, mais le PRA v1.2 n'est pas étendu automatiquement.
- Base choisie : **SQLite intégrée**, pour apprendre ce mode d'exploitation, plutôt qu'un PostgreSQL déjà familier. Le chart propose un exemple SQLite minimal *sans persistance* ; la variante **SQLite + PVC** de ce lab a été rendue à blanc et contrôlée, mais n'a pas encore été démarrée. Un futur essai PostgreSQL peut se faire sur une nouvelle instance ; ne pas présumer d'une migration automatique des données SQLite.
- Chart Helm Gitea observé : `12.7.0`, application `1.27.0`. Ses valeurs par défaut activent PostgreSQL HA et Valkey Cluster et contiennent des mots de passe d'exemple : **ne pas les utiliser**. Le dépôt Helm local était déjà configuré depuis un ancien lab, ce qui ne prouve pas qu'une ancienne Gitea existe dans les clusters actuels.

### 3.4 Préparation GitOps Gitea effectuée

- Sur management, la StorageClass `standard` (`rancher.io/local-path`) a `ReclaimPolicy=Delete`, `WaitForFirstConsumer`, sans expansion ; aucun PVC n'existait avant Gitea. Un PVC sur ce cluster **ne survivra pas à la destruction Kind comme sauvegarde PRA**.
- Le namespace `gitea` est `Active`. Le Secret `gitea-admin-secret` y a été créé manuellement, avec les clés `username` et `password`. Son mot de passe n'a pas été communiqué dans le chat ni versionné. Le mode Helm demandé est `initialOnlyNoReset` ; vérifier le comportement réel après démarrage et dans le futur test de restauration.
- Le fichier `infrastructure/gitea/values.yaml` contient : désactivation de `valkey-cluster`, `valkey`, `postgresql`, `postgresql-ha` ; `persistence.enabled: true`, `storageClass: standard`, `size: 2Gi` ; `gitea.admin.existingSecret: gitea-admin-secret` ; `database.DB_TYPE: sqlite3`, session/cache en mémoire et queue de type `level`.
- `helm template` local avec ces valeurs a réussi. Contrôles du rendu : `sqlite=True`, PVC `gitea-shared-storage` monté, `replicas=1`. Ressources vues : Secrets internes du chart, PVC, Services HTTP/SSH, Deployment et pod de test Helm. La vérification locale indiquait que le mot de passe administrateur **par défaut du chart n'apparaissait pas** dans le rendu. Ne pas diffuser le rendu intégral : il contient des Secrets générés.
- Le projet `infrastructure` autorise désormais la source Helm `https://dl.gitea.io/charts` ; l'Application `argocd/applications/gitea.yaml` utilise **deux sources** : chart Helm Gitea `12.7.0` et fichier de valeurs dans GitHub via `$values/infrastructure/gitea/values.yaml`, avec `ref: values` sans `path`. Destination : `https://kubernetes.default.svc`, namespace `gitea`.
- L'Application **n'a pas** `syncPolicy.automated`. Les trois fichiers ont été vérifiés (`git diff --cached --check`, dry-run API de l'Application et du projet) et publiés sur `main` au commit `3ccaa33bc0c550ac53383d3a04b680e639ba85a0`.
- Dernière observation : Root App `revision=3ccaa33… sync=Synced health=Healthy`. `gitea` : `OutOfSync / Missing`, `AUTO=<none>`, sans condition d'erreur ; Argo CD énumérait 7 ressources cibles `OutOfSync` (PVC, trois Secrets internes, deux Services, Deployment). `kubectl -n gitea get deployment,pods,pvc` : aucune ressource. `status.operationState` vide. **Aucun Sync Gitea effectivement enregistré**.

## 4. Point de reprise exact et garde-fous

**Au prochain démarrage, ne pas rejouer le PRA, ne pas réappliquer le chart avec Helm et ne pas répéter aveuglément le bouton Sync.** Le premier objectif est de comprendre l'état de l'interface et de déclencher *une seule* synchronisation manuelle de l'Application `gitea`, si les prérequis sont toujours satisfaits.

1. Vérifier la propreté Git et la révision de `main`, puis l'état `root-app` et `gitea`. Contrôler que le namespace et le Secret existent, en affichant **les noms de clés seulement**, jamais leurs valeurs. Vérifier qu'aucune ancienne ressource Gitea n'a été créée entre-temps.
2. Dans l'interface Argo CD, ouvrir `gitea`, examiner le dialogue **Sync** et vérifier si le bouton de confirmation interne a effectivement été actionné. Les échanges précédents ont répété la demande de Sync sans disposer de cette observation ; ne pas présumer d'un bug du chart.
3. Si le rendu et les prérequis sont inchangés, lancer un Sync **manuel** de `gitea` uniquement, sans `Force` ni `Prune`. Observer `status.operationState.phase/message`, les éventuelles conditions, puis les Deployment, pod, PVC et événements du namespace. Ne pas recopier les manifests Secrets ou les journaux contenant des valeurs sensibles.
4. Attendre et vérifier `PVC Bound`, pod `Ready`, Application `Synced/Healthy`, puis accès HTTP de Gitea par un chemin **à définir**. Le rendu contrôlé listait des Services mais **aucun Ingress Gitea n'a encore été préparé ni validé**. Ne pas prétendre que l'interface web est accessible tant qu'un accès contrôlé n'est pas mis en place et testé.
5. Relever `kubectl top` du pod et du nœud management après stabilisation ; comparer à la photographie avant Gitea. Contrôler la configuration réelle SQLite et le chemin de données sans divulguer la configuration sensible.

**Garde-fous :**

- Ne pas pousser de mot de passe, de Secret en clair, de rendu Helm complet ou de sauvegarde de base dans GitHub.
- La Root App a `prune: true` et lit `argocd/` récursivement. Éviter tout déplacement/restructuration en bloc des Applications pendant cette installation.
- La création manuelle du Secret est un prérequis de ce premier jalon, **pas** une solution de restauration validée. Avant tout PRA destructif avec des données Gitea utiles, prévoir une sauvegarde cohérente hors cluster et vérifier sa restauration.
- La valeur par défaut `helm.sh/resource-policy: keep` du chart pour le PVC ne doit pas être interprété comme une garantie de survie à `kind delete cluster` ; la StorageClass observée est `Delete`.
- Le chart et les images sont encore des dépendances externes ; ne pas présenter le résultat comme « hors Internet ».

## 5. Proposition de jalons v1.2+ : numéros et critères à confirmer

Les numéros suivants sont **des noms de jalons proposés**, non des versions déjà taguées. Ne créer tag/release qu'après preuves, documentation et validation d'un exercice réellement exécuté.

### v1.2.1 proposée : Gitea installée et intégrée sans régression

- Premier Sync manuel réussi, Gitea mono-pod sur management, SQLite sur PVC `standard`, compte administrateur via Secret externe, accès web défini et testé.
- Mesurer CPU/mémoire, vérifier fonctionnement d'un dépôt d'essai et conserver Whoami et les trois clusters fonctionnels.
- **Critère PRA à distinguer :** une Gitea *installée* n'est pas une Gitea *restaurée*. Pour appeler le jalon « PRA validé avec Gitea juste installée », rejouer le PRA sur un périmètre explicitement sans conservation des données Gitea et prouver que l'Application se recrée. Le Secret manuel manquant sur un cluster neuf constitue un blocage à résoudre ou à fournir explicitement comme prérequis avant ce test. Ne pas déclarer ce jalon acquis au seul premier Sync.

### v1.2.2 proposée : PRA avec état Gitea restauré

- Définir et éprouver la sauvegarde **hors cluster** de SQLite, dépôts Git, fichiers/configuration, identifiants nécessaires et éventuels objets du runner. Établir un ordre de restauration compatible avec GitHub comme source d'amorçage et avec la synchronisation Argo CD.
- Effectuer une reconstruction destructrice et vérifier, par des tests fonctionnels, que les dépôts, comptes et données attendus sont retrouvés. Un PVC recréé vide ne suffit pas. Définir les preuves et les limites de cohérence de sauvegarde.
- Les Secrets et fichiers hors dépôt du PRA existant doivent être pris en compte sans les publier dans Git. La politique de conservation et la protection de la sauvegarde restent à concevoir.

### v1.2.3 proposée : jeux et chaîne CI/CD restaurés

- Ajouter un Gitea Runner **distinct** de la forge ; choisir son isolation avant de lui donner accès au moteur Docker. Tester sa réinscription/restauration après PRA.
- Installer progressivement **2048, Snake et Hextris**, avec **un réplica par jeu sur dev et un sur prod** comme cible, sans remplacer Whoami. Vérifier licences, provenance des images, accès par Ingress du lab, ressources et coût réel. Le management héberge la forge, pas les jeux.
- Utiliser d'abord **2048** comme démonstrateur : modification visuelle du code, tests/build en Gitea Actions, publication d'une image versionnée, changement GitOps contrôlé sur GitHub, Argo CD sur dev, puis promotion de la **même image** en prod. Snake et Hextris peuvent rester déployés sans pipeline complet au premier passage.
- Rejouer le PRA étendu : Gitea et son runner restaurés, images accessibles, pipelines utilisables et jeux redevenus accessibles. Ne pas affirmer qu'une image distante sera récupérable sans Internet.

## 6. Horizon v1.3 et versions ultérieures : feuille de route, non engagement

**v1.3, cible proposée : plateforme CI/CD exploitable.** Selon l'ampleur des jalons v1.2.x, v1.3 pourrait être la release de synthèse de la forge Gitea, du runner, de la CI 2048 et de la promotion GitOps, avec les trois jeux installés. Fixer la convention de version après le premier jalon, plutôt que prétendre que v1.2.3 et v1.3 représentent deux réalisations déjà distinctes.

**Harbor, candidat v1.4.** Étudier registre privé, stockage des images applicatives et éventuellement des artefacts OCI, politique d'accès et sauvegarde, puis migrer progressivement les références d'images. Harbor n'est pas seulement un cache, mais il ne remplace pas Git ni le runner CI. Vérifier la dépendance circulaire : un Harbor détruit avec management ne peut pas servir les images nécessaires à sa propre reconstruction sans source d'amorçage indépendante.

**PRA à dépendance Internet réduite, chantier ultérieur.** Inventorier chaque téléchargement : image du nœud Kind, images Kubernetes et applicatives, charts Helm, outils de `bootstrap-workstation`, GitHub et autres dépôts. Définir le scénario exact à tester, par exemple « registres publics indisponibles, GitHub joignable », distinct d'un véritable PRA air-gapped. Précharger/répliquer les artefacts requis et tester sur des nœuds reconstruits, pas seulement sur le cache Docker du portable.

**PRA compatible VM nue, chantier ultérieur.** Préparer un kit de prérequis et de sauvegardes **hors dépôt** (notamment manifeste Argo CD vérifié et clé Sealed Secrets), rendre les paramètres réseau et les chemins portables, puis exécuter une restauration sur une VM différente. Un clone local de `main` seul ne suffit pas à recréer l'état Gitea ni à alimenter les dépôts Helm et registres. Mesurer les ressources de la VM et qualifier explicitement le scénario avec ou sans Internet.

**Autres pistes à réévaluer après ces jalons :** Vault et gestion des secrets ; Terraform/Ansible pour l'infrastructure et la configuration si la portabilité multi-machine le justifie ; réorganisation d'`argocd/applications` ou ApplicationSet avec labels de clusters. Aucun de ces chantiers ne doit être confondu avec la correction immédiate de Gitea. Les Secrets de cluster Argo CD observés n'avaient pas de labels `env`, et une restructuration sous auto-prune exige une migration préparée.

## 7. Décisions, hypothèses et questions ouvertes

| Sujet | Statut en fin de séance |
| --- | --- |
| PRA v1.2 management/dev/prod | Validé lors de l'exercice documenté et tagué ; dépendances externes conservées. |
| Metrics Server sur trois clusters | Vérifié par API Metrics et `kubectl top` durant cette séance. |
| Gitea sur management via Argo CD | Déclarée dans Git et visible dans Argo CD ; **non synchronisée, non installée**. |
| SQLite + PVC 2 Gi | Rendu Helm vérifié ; démarrage, performance et restauration non prouvés. |
| Secret administrateur | Présent manuellement dans le namespace `gitea` ; pas de sauvegarde PRA validée. |
| Ingress et URL Gitea | À concevoir et tester ; ne pas supposer l'accès externe. |
| Gitea Runner | Non installé ; mode d'exécution et sécurité à choisir. |
| Trois jeux | Non installés ; 2048 sera le premier pilote CI. |
| GitLab.com / GitLab local | Options discutées, **non retenues pour ce jalon** ; Gitea local préféré pour apprendre l'administration. |
| Harbor, PRA hors Internet, VM nue | Objectifs futurs non implémentés et non validés. |

## 8. Références officielles à reconsulter lors de l'exécution

- Gitea : installation Kubernetes et chart Helm ; lire le README et les valeurs **de la version fixée** avant chaque changement.
- Gitea : préparation des bases et avertissement sur la conversion entre moteurs.
- Gitea : sauvegarde/restauration cohérente de la base, des dépôts et des fichiers.
- Argo CD : Applications multi-sources avec `$values`, synchronisation manuelle et `status.operationState`.
- Kubernetes : politique de récupération des volumes et distinction entre requests, limits et mesures `kubectl top`.

Les références externes sont indicatives ; **les sorties de commandes et commits cités dans ce document sont les preuves propres au lab**. Ne pas traiter une recommandation documentaire comme une preuve d'exécution locale.
