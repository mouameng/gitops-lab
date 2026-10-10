# GitOps Lab — Capitalisation v1.2.2 : CA privée, TLS durable, PRA validé (version clôturée)

**Statut : v1.2.2 clôturée le 7 octobre 2026.** PRA multicluster rejoué et validé techniquement, tag `v1.2.2` publié sur GitHub.
**Révision de référence :** le tag `v1.2.2` désigne la révision qui **ajoute ce document** ; son parent est `d9f9a45` (révision restaurée et poussée pendant le PRA). Le hash du commit de clôture n'est pas inscrit ici, car un document ne peut pas contenir le hash du commit qui l'ajoute ; utiliser `git rev-parse 'v1.2.2^{commit}'`.
**Remplace :** gitops-lab-capitalisation-v1.2.2-pra-valide-2026-10-07.md (tag alors indiqué « à faire »), et avant elle …-tls-2048-valides-pra-a-faire.md, …-tls-ca-bascule-validee-pra-a-faire.md, …-tls-ca-pra-en-cours.md. L'historique utile est conservé.
**Référence historique :** gitops-lab-capitalisation-v1.2.1-gitea-PRA-travaux-realises-2026-10-06.md (PRA multicluster avec Gitea validé en v1.2.1).
**Périmètre :** lab personnel Kind/GitOps (management + workloads dev/prod), forge Gitea, certificats des interfaces locales, confiance des clients (WSL et Windows/Chrome), dépôt applicatif 2048.

**Convention de lecture :**
- **confirmé** : sortie ou test rapporté dans les échanges ;
- **préparé** : changement local ou dry-run ;
- **à valider** : pas encore démontré en situation cible.

Une commande citée sans résultat ne vaut pas preuve de son exécution.

---

## 1. Synthèse

Après la v1.2.1, le plan était d'alimenter Gitea avec 2048, Snake et Hextris, de les déployer sur les workloads, de mesurer leur consommation, puis de rejouer un PRA élargi. Le clone HTTPS de `gitea_admin/2048` a échoué (*certificate signer not trusted*) : Gitea et Argo CD utilisaient des certificats directement auto-signés.

**Décision :** mettre d'abord en place une identité TLS stable et restaurable avec une CA privée, puis reprendre l'alimentation des dépôts.

**Résultat (v1.2.2 clôturée) :**
- La CA privée **GitOps Lab Root CA** signe les certificats de Gitea et d'Argo CD.
- La confiance est installée sur Ubuntu/WSL (magasin système) et Windows (magasin utilisateur, utilisé par Chrome).
- Le dépôt `gitea_admin/2048` est cloné, alimenté et poussé en HTTPS avec vérification TLS (`8c32cea`). Les tests Node, le build Docker et le jeu dans le conteneur sont validés.
- **PRA v1.2.2 validé** (section 4.11) : même CA restaurée, certificats réémis par elle, Gitea restauré avec les commits 2048, clients fonctionnels **sans réinstallation de confiance**.
- **Tag `v1.2.2` publié** sur la révision qui contient ce document (section 4.12).
- **Hors v1.2.2, reporté :** changement du mot de passe admin Argo CD ; publication de l'image et déploiement de 2048 sur les clusters (objet de la v1.2.3).

## 2. Architecture de référence et limites

- `gitops-management` héberge Argo CD (v3.5.3), cert-manager, Traefik et Gitea (chart 12.7.0). `gitops-dev` et `gitops-prod` hébergent les workloads.
- GitHub (`mouameng/gitops-lab`) reste la source d'amorçage et des manifests GitOps. Gitea héberge le code des jeux ; son intégration comme source Argo CD n'est pas réalisée.
- Gitea reste mono-réplique (SQLite, PVC, stratégie Recreate). Ses données sont restaurées **avant** la Root App.

**Applications et politiques de synchronisation :**

| Application | Chemin | Synchronisation | Contenu TLS |
|---|---|---|---|
| cert-manager-config | infrastructure/cert-manager | **automatique** (prune, selfHeal), sync-wave -25 | ClusterIssuer historique, gitops-lab-ca-issuer, certificat Argo CD |
| gitea-external | applications/gitea | **manuelle** | certificat Gitea, IngressRoute |
| gitea | chart Helm + values GitHub | **manuelle** | — |

- **Conséquence :** un push touchant `infrastructure/cert-manager` est appliqué automatiquement ; un push touchant `applications/gitea` nécessite une synchronisation manuelle (faite explicitement par le bootstrap lors du PRA).
- `infrastructure/cert-manager` ne contient pas de `kustomization.yaml` : Argo CD charge directement les fichiers YAML du dossier.
- Le PRA dépend de sources externes (GitHub, charts, images). La copie chiffrée de la CA sur Google Drive personnel est une copie hors poste, pas une reprise hors Internet, et le bootstrap ne la télécharge pas.

## 3. Choix TLS v1.2.2

- **CA :** GitOps Lab Root CA. Son certificat public est approuvé par les clients ; sa clé privée est restaurée à l'identique avant toute émission de certificat de service.
- **Issuer :** ClusterIssuer `gitops-lab-ca-issuer`, qui référence le Secret `gitops-lab-root-ca` dans le namespace `cert-manager`.
- **Indépendance des identités :** la clé Sealed Secrets et la clé de la CA sont deux identités distinctes, avec des sauvegardes et des contrôles propres.
- **Distribution :** seul le certificat **public** de la CA est copié sur les clients, **jamais la clé privée**. Aucune désactivation de la vérification TLS.
- **Limite assumée :** montage pédagogique, pas une PKI d'entreprise. Un serveur PKI (avec autorité intermédiaire) reste un sujet d'apprentissage ultérieur.
- **Intérêt démontré par le PRA :** la CA étant restaurée à l'identique, les certificats réémis après reconstruction sont approuvés par les clients sans réinstaller la confiance.

## 4. Travaux réalisés et preuves

### 4.1 Diagnostic du blocage (6 octobre)
- Le clone de `gitea_admin/2048` a échoué avant la création du dossier local ; les erreurs `cd` et `not a git repository` qui ont suivi en étaient des conséquences.
- `openssl s_client` signalait *self-signed certificate* (code 18) ; le SAN contenait bien `DNS:gitea.local`.
- Les certificats utilisaient `selfsigned-cluster-issuer` (`selfSigned: {}`).
- Le clone a été suspendu, sans désactiver la vérification SSL.

### 4.2 Paire CA locale et sauvegarde hors poste (6 octobre)
- Fichiers : `~/.config/gitops-lab/gitops-lab-root-ca.crt` et `.key`, hors du dépôt Git. Répertoire en 700, fichiers en 600.
- Certificat : `CN=GitOps Lab Root CA`, `CA:TRUE`, usages Certificate Sign et CRL Sign, valide du 6 octobre 2026 au 3 octobre 2036.
- **Empreinte SHA-256 de référence :** `AD:AF:8D:2F:A2:55:8D:23:42:2A:98:75:5D:6D:01:77:EC:4E:EA:17:35:0A:CE:28:AA:57:79:0A:D5:A3:A1:92`.
- Cohérence clé/certificat vérifiée par comparaison des clés publiques dérivées.
- Archive chiffrée `gitops-lab-root-ca.tar.age` (age 1.2.1, phrase de passe), sans archive intermédiaire en clair. La copie Google Drive a été retéléchargée avec une empreinte identique (`95f0d9d7…2f88c`) et déchiffrée avec succès.
- **La phrase de passe ne figure ni dans ce document ni dans le même espace cloud.** La perte simultanée des fichiers en clair et de la phrase de passe imposerait une nouvelle CA et une nouvelle distribution de la confiance.

### 4.3 Secret CA et ClusterIssuer
- Secret `gitops-lab-root-ca` créé initialement à la main sur le management (type `kubernetes.io/tls`, empreinte et clé vérifiées).
- ClusterIssuer versionné dans `infrastructure/cert-manager/gitops-lab-ca-issuer.yaml` ; dry-run `unchanged`, READY=True. Après push, `cert-manager-config` est Synced/Healthy sur `7b6b708`, sans condition d'erreur (après `refresh=hard`). Aucun conflit avec la ressource créée manuellement.
- `selfsigned-cluster-issuer` reste déclaré mais n'est plus référencé par Gitea ni par Argo CD.

### 4.4 Bootstrap PRA
**Ajouts dans `scripts/bootstrap-platform.sh` (92 lignes) :**
- **Prévol, avant la sortie `--preflight` et avant toute destruction :** fichiers CA présents et lisibles, refus des liens symboliques, certificat non expiré, `CA:TRUE`, égalité des clés publiques.
- **Après reconstruction, avant Sealed Secrets et la Root App :** namespace `cert-manager`, **refus d'écraser** un Secret CA existant, création du Secret depuis les fichiers locaux, comparaison de l'empreinte du certificat et de la clé publique restaurés.

**Contrôles :** script en `set -euo pipefail` ; `bash -n`, `git diff --check` et `git diff --cached --check` sans erreur ; prévol complet en code 0 (`[OK] Paire CA locale validée avant destruction`).

**Leçon :** la garde Git du prévol exige que le commit soit **publié**, pas seulement enregistré localement (`[STOP] main local et origin/main diffèrent`). C'est voulu : le PRA reconstruit depuis GitHub.

**Exécution réelle :** validée lors du PRA (4.11).

### 4.5 Bascule du certificat Gitea (7 octobre)
- `applications/gitea/certificate.yaml` : `issuerRef.name` passe à `gitops-lab-ca-issuer`. Ressource `gitea-local`, Secret `gitea-local-tls` et SAN `gitea.local` inchangés.
- Diff Argo CD limité à cette ligne ; synchronisation manuelle **ciblée sur la seule ressource Certificate** (`b856d10`) : Succeeded.
- Certificat réémis : révision 2, Ready=True, émis par la CA, SAN `DNS:gitea.local` (critique), sujet vide. Le certificat servi par Traefik a été vérifié (`Verification: OK`, `Verified peername: gitea.local`).

### 4.6 Bascule du certificat Argo CD (7 octobre)
- `infrastructure/cert-manager/argocd-certificate.yaml` : même changement d'Issuer, appliqué **automatiquement** par `cert-manager-config` (`c6bbeff`).
- Certificat réémis : révision 2, Ready=True, émis par la CA.

### 4.7 Confiance côté clients (7 octobre)
**Ubuntu/WSL :**
- Certificat public copié dans `/usr/local/share/ca-certificates/gitops-lab-root-ca.crt`, puis `update-ca-certificates` : `1 added`. L'avertissement `rehash: skipping ca-certificates.crt` concerne le fichier groupé et reste sans effet.
- `curl` vers Gitea et Argo CD : HTTP/2 200 sans CA explicite.
- `git -c http.sslVerify=true ls-remote` sur le dépôt 2048 : succès.

**Windows / Chrome :**
- Diagnostic : Chrome sous Windows utilise le magasin Windows, pas celui de WSL ; une **exception manuelle** existait aussi sur `argocd.local`.
- Certificat public copié dans Downloads (`cmp` identique, empreinte AD:AF:…), puis `Import-Certificate` dans **`Cert:\CurrentUser\Root`** (sans élévation). Empreinte SHA-1 Windows : `11ACB678E4470B326FA020629186DB5013C81182` ; SHA-256 recalculée depuis le magasin : identique à la référence.
- `gitea.local` sécurisé ; `argocd.local` avec la hiérarchie GitOps Lab Root CA → argocd.local.

**Pièges :**
- Sous Windows, le Thumbprint est en **SHA-1** et `Get-FileHash` porte sur le **fichier** : ne pas les comparer à l'empreinte SHA-256 du certificat.
- Certificats de service sans CN : c'est normal, la validation se fait sur le SAN.

### 4.8 Argo CD CLI en mode `--core` (savoir-faire)
- Version CLI v3.5.3. `--namespace` n'existe pas pour `app diff` ; utiliser `--app-namespace`.
- En mode `--core`, la CLI cherche `argocd-cm` dans le **namespace du contexte kube** ; sinon `configmap "argocd-cm" not found`.
- Solution sans toucher au kubeconfig habituel : kubeconfig temporaire (`umask 077`, `mktemp`, `trap`), extrait avec `config view --minify --raw --flatten` et positionné sur `argocd`. Ne jamais afficher ce fichier. Le bootstrap applique le même principe (`--namespace=argocd`).
- `argocd app diff` renvoie **1 quand un diff existe** (ce n'est pas une erreur), 2 en cas d'erreur.
- Sync ciblée : `--resource cert-manager.io:Certificate:gitea/gitea-local`.

### 4.9 Historique Git gitops-lab

| Commit | Contenu | Effet |
|---|---|---|
| 7b6b708 | feat(tls): add lab CA issuer and bootstrap CA restore guards | Issuer pris en charge par cert-manager-config |
| b856d10 | feat(tls): use lab CA issuer for Gitea certificate | Sync manuelle ciblée |
| c6bbeff | feat(tls): use lab CA issuer for Argo CD certificate | Appliqué automatiquement ; révision testée par le PRA |
| d9f9a45 | chore(pra): renew workload registrations | Poussé **par le bootstrap pendant le PRA** (SealedSecrets dev/prod) |
| *(commit de clôture)* | docs: add v1.2.2 capitalisation (PRA validé) | Porte le tag `v1.2.2` ; ajoute uniquement ce document |

- Les sauvegardes `scripts/*.before-*` restent **non suivies**. Ne pas les ajouter avec `git add .`.
- Fichiers `*:Zone.Identifier` (ajoutés par Windows au téléchargement) : à supprimer, jamais à commiter.

### 4.10 Dépôt 2048 : clone, intégration et image locale (7 octobre)
**Clone HTTPS :** `git -c http.sslVerify=true clone … 2048-repo`, sans `GIT_SSL_NO_VERIFY` : réussi. **Dépôt de travail : `~/lab/2048-repo`.** `~/lab/2048` reste une copie source non suivie (avec le ZIP, et **sans** le correctif MIME). Relancer le clone échoue proprement (*destination path already exists*) sans rien écrire.

**Intégration :**
- Simulation `rsync --dry-run --itemize-changes` : ZIP et `.git` exclus ; seul conflit : `README.md`.
- README local conservé, complété par la phrase d'objectif du README initial.
- Permissions normalisées (`--chmod=D755,F644`).
- 4 tests Node réussis dans le dépôt ; 8 fichiers indexés explicitement. Identité Git : Stéphane VANG `<stephane.vang@lab.local>`.

**Image Docker (`nginx:stable-alpine`, nginx 1.30.5) :**
- Premier build : `logic.mjs` servi en `application/octet-stream`. `mime.types` n'associe `application/javascript` qu'à `js`, or `app.js` (chargé en `type="module"`) importe `./logic.mjs`. En local, `python3 -m http.server` masquait le problème.
- **Correctif :** `RUN sed` ajoutant `mjs`, puis `grep -Eq` (le build échoue si le remplacement ne s'applique pas) et `nginx -t`.
- Résultat : `app.js` et `logic.mjs` servis en `application/javascript`, **jeu validé dans Chrome** (grille, déplacements, score). Image locale `2048-lab:dev` uniquement, non publiée.

**Historique `gitea_admin/2048` :**

| Commit | Contenu |
|---|---|
| d673042 | Initial commit |
| 22e9bd3 | feat: add original 2048 implementation with tests and Dockerfile |
| 8c32cea | fix(image): serve .mjs modules as application/javascript in nginx |

### 4.11 Recette PRA v1.2.2 (7 octobre 2026)
**Préparation :**
- `gitops-lab` aligné sur `c6bbeff`, avec seulement les `*.before-*` non suivis ; prévol en code 0 avec la garde CA.
- Séquence relue dans le script : menu interactif (refus par défaut) → sauvegarde Gitea fraîche `--backup`, jeu `[SELECT]` au format AAAAMMJJ-HHMMSS puis `--validate` → `kind delete` → recréation → Argo CD sans Root App → **restauration et vérification de la CA (l. 457-513)** → clé Sealed Secrets → **restauration Gitea (l. 762-770)** → Root App → sync explicite de `gitea` et `gitea-external`, puis attente Synced/Healthy.
- Relevé de référence sans secret : `~/.local/share/gitops-lab/pra/pra-v1.2.2-avant-20261007-152725.txt`.

**Exécution :** bootstrap sans argument, choix 2. Journal Argo CD : `~/.local/share/gitops-lab/logs/argocd-sync.aUqQZhVo.log`.

**Comparaison avant / après :**

| Contrôle | Avant | Après | Verdict |
|---|---|---|---|
| Empreinte CA (cluster) | AD:AF:…:A3:A1:92 | AD:AF:…:A3:A1:92 | ✅ identité conservée |
| Issuer gitops-lab-ca-issuer | Ready=True | READY=True | ✅ |
| Certificates Gitea / Argo CD | CA Issuer | CA Issuer, Ready=True | ✅ |
| Certificat servi gitea.local | 40:0B:…:6C:05 | F7:F7:8C:3A:…:32:87, émis par la CA | ✅ réémis (empreinte différente, attendu) |
| Certificat servi argocd.local | 7A:F1:…:08:C5 | 0C:44:AA:5E:…:25:0C, émis par la CA | ✅ réémis |
| curl Gitea / Argo CD | 200 | 200, sans CA explicite | ✅ |
| Git HTTPS 2048 (sslVerify=true) | 8c32cea | 8c32cea | ✅ |
| Chrome Windows | sécurisé | gitea.local et argocd.local sans « Non sécurisé » | ✅ sans réimport |
| Gitea (UI) | — | dépôts 2048 et gitea-test, commits 8c32cea et 22e9bd3 | ✅ |

Les commits `22e9bd3` et `8c32cea` sont postérieurs à l'ancien jeu `20261006-195056` : leur présence prouve que **la sauvegarde prise juste avant la destruction** a bien été restaurée.

**Constats annexes :**
- `gitea` (chart 12.7.0) passe de Progressing à Healthy ; `gitea-external` recrée le Certificate `gitea-local` et l'IngressRoute, Synced/Healthy.
- **Warning PVC sans gravité :** `gitea-shared-storage` est créé par `restore-gitea.sh` avant Argo CD, sans annotation `last-applied-configuration` ; l'annotation est ajoutée automatiquement, PVC Healthy.
- **Commit `d9f9a45`** poussé pendant le PRA : renouvellement des enregistrements dev/prod, uniquement des **SealedSecrets** (chiffrés). Les Applications Gitea sont synchronisées sur cette révision.
- **Alerte Chrome** « mot de passe détecté lors d'une violation de données » à la connexion Argo CD : sans lien avec TLS. Le mot de passe admin est trop courant ; son hash étant restauré par le bootstrap, le changement doit passer par le mécanisme de la v1.2.1.

### 4.12 Clôture et publication (7 octobre 2026)
- Dépôt local aligné sur `origin/main` (`d9f9a45`) : `git pull --ff-only` → *Already up to date*.
- Ce document est ajouté par un commit dédié, sans les `scripts/*.before-*` ni le fichier `Zone.Identifier`.
- Un tag annoté `v1.2.2` (objet `a0759e1`) avait d'abord été publié sur `d9f9a45`, révision qui ne contenait pas la documentation de clôture. Lab mono-utilisateur, aucune référence au tag dans les manifests : il a été **supprimé puis reposé** (annoté) sur ce commit de clôture et republié. Décision assumée et exceptionnelle ; un tag publié n'est plus déplacé ensuite.
- Vérification : `git ls-remote --tags origin 'v1.2.2*'` (le pointeur `^{}` désigne le commit de clôture, dont le parent est `d9f9a45`).
- Tags existants : `v1.2.0-pra-multicluster-ok`, `v1.2.1-pra-gitea-ok`, `v1.2.2`.

## 5. État de validation v1.2.2

| Critère | État | Preuve ou limite |
|---|---|---|
| Paire CA locale cohérente | **Validé** | Prévol automatique |
| Archive chiffrée et copie Drive | **Validé** | Empreintes identiques, déchiffrement |
| Changements publiés, aucun secret dans Git | **Validé** | Commits ciblés, diffs relus |
| Prévol complet du bootstrap | **Validé** | Code 0, garde CA atteinte |
| Certificats Gitea et Argo CD signés par la CA | **Validé** | Avant et après PRA |
| Confiance Ubuntu/WSL | **Validé** | curl, Git avec sslVerify=true |
| Confiance Windows/Chrome | **Validé** | CA identique, sites sécurisés |
| Clone et push HTTPS de gitea_admin/2048 | **Validé** | 8c32cea |
| Image 2048 locale | **Validé** (local) | MIME corrigé, jeu testé ; non publiée |
| Restauration du Secret CA sur un management neuf | **Validé** | Empreinte identique après reconstruction |
| PRA TLS v1.2.2 complet | **Validé** | Section 4.11 |
| Tag v1.2.2 publié | **Validé** | Section 4.12 |

## 6. Points de vigilance
- **Renouvellement :** les certificats de service valent environ 90 jours (jusqu'au 5 janvier 2027). Le renouvellement automatique par cert-manager n'a pas encore été observé ; il conserve la même CA, donc la même confiance.
- **Sécurité des preuves :** ne jamais afficher ou commiter la clé de la CA, l'archive déchiffrée, un Secret complet, la phrase de passe ou un kubeconfig. Inutile de partager les blocs SSL-Session (dont le Resumption PSK) des sorties `openssl s_client`.
- **Rotation de la CA :** non planifiée. Une nouvelle CA imposerait une redistribution de la confiance sur WSL et Windows.
- **Tags publiés :** ne plus déplacer `v1.2.2`. Toute correction ultérieure passe par une nouvelle version.

## 7. Feuille de route
- ~~Cloner et alimenter gitea_admin/2048~~ : **fait** (4.10).
- ~~Préparer et rejouer le PRA v1.2.2~~ : **fait et validé** (4.11).
- ~~Aligner le dépôt local et poser le tag v1.2.2~~ : **fait** (4.12).
- **v1.2.3 — 2048 en ligne et PRA élargi** (*à valider*) :
  1. choisir et activer le registre (orientation : registre intégré à Gitea, pour que l'image soit couverte par la sauvegarde Gitea déjà validée ; alternative : GHCR) ;
  2. publier l'image 2048 avec une référence immuable (digest) ;
  3. rendre le registre accessible depuis les nœuds Kind dev et prod (résolution de `gitea.local`, confiance dans la CA), via le bootstrap ;
  4. créer les manifests 2048 dans GitHub (base, overlay dev puis prod, requests/limits) ;
  5. exposer 2048 en HTTPS avec un certificat émis par la CA du lab ;
  6. rejouer le PRA v1.2.3 avec 2048 « en ligne » dans le périmètre, puis poser le tag v1.2.3.
- **Ensuite :** CI de modification et de livraison vers les clusters de workload (runner Gitea, pipeline de build et de publication, mise à jour des manifests).
- **Point distinct :** changer le mot de passe admin Argo CD via le mécanisme de hash du bootstrap, puis vérifier qu'un PRA le conserve.

## 8. Chantier applicatif

### 8.1 2048
- Dépôt `gitea_admin/2048` alimenté (`8c32cea`) ; dépôt de travail `~/lab/2048-repo`. Le dépôt témoin `gitea_admin/gitea-test` existe encore.
- Implémentation **originale** : l'import du projet de Gabriele Cirulli a été abandonné ; ne pas lui attribuer sa licence MIT.
- Restent à définir : registre, publication de l'image et **épinglage de l'image de base par digest** (`nginx:stable-alpine` est un tag mobile).
- Manifests dans GitHub, sources dans Gitea. Prévoir un overlay dev avant prod, une image immuable et des requests/limits adaptés ; ne pas recopier tels quels les 3 réplicas sans requests/limits du modèle whoami.

### 8.2 Snake, Hextris et PRA élargi
- Dépôts non créés. Choisir une implémentation dont la provenance et la licence sont claires, ou écrire un code original.
- Déploiement progressif en dev puis en prod, sans retirer whoami.
- Mesures de référence avant les jeux : dev **135 mCPU / 1 233 MiB**, prod **144 mCPU / 1 228 MiB** ; requests **1 150 mCPU / 580 MiB** sur chacun.
- Runner Gitea, CI/CD et registre privé : jalons distincts, non installés.
- Ne nettoyer `gitea-test` qu'après avoir remplacé son rôle de témoin dans la recette.

## 9. Dépendances, risques et décisions ouvertes
- **Copie cloud de la CA :** en cas de perte du poste, récupérer l'archive sur Drive et la déchiffrer avant le bootstrap. Dépendances : accès au compte Google et phrase de passe.
- **Clients approuvant la CA :** WSL et Windows (`CurrentUser\Root`). Tout nouveau poste, ou tout navigateur doté de son propre magasin, devra recevoir le certificat public. **En v1.2.3, les nœuds Kind deviendront aussi des clients de la CA** s'ils tirent les images depuis Gitea.
- **Retrait de la confiance :** supprimer le fichier puis lancer `update-ca-certificates` sous Ubuntu ; supprimer le certificat `11ACB678…` de `CurrentUser\Root` sous Windows.
- **selfsigned-cluster-issuer :** toujours déclaré, plus utilisé. Retrait à décider après avoir vérifié qu'aucune ressource ne le référence.
- **Mot de passe admin Argo CD :** signalé comme compromis par Chrome. À changer.
- **Serveur PKI :** sujet d'apprentissage ultérieur, également pertinent professionnellement.

## 10. Critères de clôture de v1.2.2

| Critère | État |
|---|---|
| Changements publiés, prévol propre, aucun secret dans Git | ✅ Atteint |
| Certificats Gitea et Argo CD signés par la CA, certificat servi vérifié | ✅ Atteint |
| Confiance des clients, HTTPS sans désactivation TLS | ✅ Atteint |
| Clone HTTPS de gitea_admin/2048 | ✅ Atteint |
| Même identité CA après reconstruction, Issuer Ready=True | ✅ Atteint |
| PRA multicluster rejoué, contrôles TLS sans réinstallation de confiance | ✅ Atteint |
| Journal de recette sans secrets, documentation à jour | ✅ Atteint |
| Tag v1.2.2 publié sur la révision documentée | ✅ Atteint |

**Version clôturée.** Point de reprise : v1.2.3, étape 1 (choix et activation du registre).

## Sources de référence
- Capitalisation v1.2.1 et versions précédentes de ce document.
- Preuves v1.2.2 : sorties de commandes, diffs, captures et relevés avant/après PRA des 6 et 7 octobre 2026.
- Documentation officielle : cert-manager, Argo CD, Git, OpenSSL, Ubuntu. Elle décrit les outils mais ne prouve pas l'état du lab.
