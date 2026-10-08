# GitOps Lab — Capitalisation v1.2.3 : 2048 en ligne (registre Gitea), accès des nœuds au registre, PRA rejoué deux fois

**Statut : v1.2.3 clôturée le 7 octobre 2026.** 2048 est en ligne sur dev et prod, son image est stockée dans le registre OCI de Gitea, et le PRA multicluster a été rejoué **deux fois** avec le même résultat, image comprise.
**Révision de référence :** le tag `v1.2.3` désigne la révision qui **ajoute ce document** ; son parent est `857bf6b` (commit poussé par le bootstrap au second PRA). Le hash du commit de clôture n'est pas inscrit ici (un document ne peut pas contenir le hash du commit qui l'ajoute) : utiliser `git rev-parse 'v1.2.3^{commit}'`.
**Remplace :** gitops-lab-capitalisation-v1.2.2-cloturee-2026-10-07.md. Le contenu utile de la v1.2.2 (CA privée, TLS) est repris en section 3. Les versions plus anciennes restent dans `docs/`.
**Périmètre :** lab personnel Kind/GitOps (management + workloads dev/prod), forge Gitea et son registre, CA privée, jeu 2048.

**Convention de lecture :**
- **confirmé** : sortie ou capture rapportée dans les échanges ;
- **hypothèse** : explication cohérente avec les observations, non prouvée ;
- **à valider** : pas encore démontré.

Une commande citée sans résultat ne vaut pas preuve de son exécution.

---

## 1. Synthèse

Après la v1.2.2 (CA privée, certificats durables, PRA validé), l'objectif était de **mettre 2048 en ligne** sur les clusters de workload, puis de **prouver par un PRA** que tout est restauré, image comprise.

**Décisions :**
- **Registre :** le registre OCI intégré à Gitea. L'image est stockée sur le PVC de Gitea, donc couverte par la sauvegarde et la restauration déjà validées.
- **Lecture anonyme :** le compte `gitea_admin` est public ; les nœuds téléchargent sans `imagePullSecret`.
- **Référence immuable :** l'image est référencée par **digest**, jamais par un tag mobile.
- **Manifests dans GitHub, code dans Gitea** (principe conservé de la v1.2.2).
- **Accès des nœuds :** résolution de `gitea.local` et confiance dans la CA posées par un script rejouable, appelé par le bootstrap, avec un patch containerd dans les `kind-config`.

**État au 7 octobre 2026 :**
- Image `gitea.local/gitea_admin/2048` publiée, digest `sha256:c76fe9312b4e7dc20bd08117023d337c604274c4bc613b6690fc70200e892b7d` (source : commit `8c32cea` de `gitea_admin/2048`).
- 2048 déployé sur dev puis prod (Applications `game-2048-dev` et `game-2048-prod`), jeu validé dans Chrome sur les deux.
- **PRA v1.2.3 rejoué deux fois :** même CA, certificats réémis, 16 fichiers `packages` restaurés, `config_path` posé par le patch Kind, `configure-workload-registry.sh` appelé par le bootstrap, pods 2048 qui téléchargent l'image sur des clusters neufs, 25 Applications `Synced` / `Healthy`.
- **Reporté (points ouverts, section 8) :** HTTPS de 2048, garde sur `packages/` dans la validation de sauvegarde, ordre de démarrage 2048/Gitea, mot de passe admin Argo CD, CI.

## 2. Architecture de référence

### 2.1 Clusters et réseau
- **Clusters Kind :** `gitops-management` (Argo CD v3.5.3, cert-manager, Traefik, Gitea 1.27.0 chart 12.7.0), `gitops-dev`, `gitops-prod`. Nœuds Kubernetes v1.37.0, containerd v2.3.4.
- **Réseau Docker `kind` :** management `172.18.0.2`, dev `172.18.0.3`, prod `172.18.0.4` (valeurs observées ; **l'IP du management est recalculée à chaque exécution** du script d'accès au registre, car elle peut changer à la recréation).
- **Ingress des workloads :** ingress-nginx derrière MetalLB, dev `172.18.250.200`, prod `172.18.255.200`. **HTTP uniquement** ; cert-manager n'est **pas** installé sur les workloads (0 CRD).
- **Chemin du navigateur :** fichier hosts Windows (`127.0.0.1`) → ports 80/443 publiés par le nœud management → Traefik. Les IngressRoutes `workload-dev` et `workload-prod` (entrypoint `web`, HostRegexp `^.+\.dev\.local$` et `^.+\.prod\.local$`) relaient vers les workloads. Elles couvrent déjà `2048.dev.local` et `2048.prod.local`.
- **Gitea :** IngressRoute sur l'entrypoint **`websecure` uniquement** : `http://gitea.local` renvoie le 404 en texte brut de Traefik, `https://gitea.local` répond 200.

### 2.2 Chaîne de livraison de 2048

```text
Code (Gitea gitea_admin/2048) → docker build/push → registre Gitea
   gitea.local/gitea_admin/2048@sha256:c76fe93…
Manifests (GitHub applications/games/2048, digest dans l'overlay) → Argo CD → workload
kubelet → containerd → https://gitea.local (résolu vers l'IP du management, CA dans certs.d)
```

### 2.3 Applications et synchronisation
Les 25 Applications sont `Synced` / `Healthy` après chaque PRA. Ajouts de la v1.2.3 :

| Application | Chemin | Destination | Synchronisation |
|---|---|---|---|
| game-2048-dev | applications/games/2048/overlays/dev | workload-dev, ns `game-2048` | automatique (prune, selfHeal) |
| game-2048-prod | applications/games/2048/overlays/prod | workload-prod, ns `game-2048` | automatique (prune, selfHeal) |

- **Root App :** elle ne surveille que `argocd/` (branche `main`, récursif). Un fichier ajouté dans `argocd/applications/` déclenche un déploiement ; `clusters/`, `scripts/`, `docs/` n'ont aucun effet sur Argo CD.
- **Projet `applications` :** dépôt GitHub unique en `sourceRepos`, destinations `workload-dev` et `workload-prod` (tous namespaces), ressource cluster autorisée : `Namespace`. `game-2048` passe sans modification.
- **gitea et gitea-external :** synchronisation **manuelle**, faite par le bootstrap après la Root App (inchangé depuis la v1.2.2).

## 3. Rappel v1.2.2 : CA privée et TLS (conservé)

- **CA :** `GitOps Lab Root CA`, valide du 6 octobre 2026 au 3 octobre 2036. Fichiers `~/.config/gitops-lab/gitops-lab-root-ca.crt` et `.key` (répertoire 700, fichiers 600), hors du dépôt.
- **Empreinte SHA-256 de référence :** `AD:AF:8D:2F:A2:55:8D:23:42:2A:98:75:5D:6D:01:77:EC:4E:EA:17:35:0A:CE:28:AA:57:79:0A:D5:A3:A1:92`. Identique avant et après chaque PRA.
- **Sauvegarde hors poste :** archive chiffrée `gitops-lab-root-ca.tar.age` (age) copiée sur Drive ; la phrase de passe n'est ni dans ce document ni dans le même espace cloud.
- **Issuer :** ClusterIssuer `gitops-lab-ca-issuer` (Secret `gitops-lab-root-ca`, namespace `cert-manager`), restauré par le bootstrap **avant** la Root App, avec refus d'écraser un Secret existant.
- **Certificats de service :** Gitea et Argo CD, **réémis à chaque PRA** (empreintes différentes, même CA, donc même confiance). Durée d'environ 90 jours ; le renouvellement automatique n'a pas encore été observé.
- **Clients :** Ubuntu/WSL (`/usr/local/share/ca-certificates/` + `update-ca-certificates`) et Windows (`Cert:\CurrentUser\Root`, SHA-1 `11ACB678E4470B326FA020629186DB5013C81182`). Seul le certificat **public** est distribué.
- **Pièges conservés :** Thumbprint Windows en SHA-1 et `Get-FileHash` sur le fichier (ne pas comparer au SHA-256 du certificat) ; certificats sans CN (validation sur le SAN).
- **Argo CD CLI en `--core` :** la CLI cherche `argocd-cm` dans le namespace du contexte kube ; utiliser un kubeconfig temporaire positionné sur `argocd` (`--minify --raw --flatten`, `umask 077`, `trap`). `argocd app diff` renvoie 1 quand un diff existe.
- **Limite assumée :** montage pédagogique, pas une PKI d'entreprise. Un serveur PKI (autorité intermédiaire) reste un sujet d'apprentissage ultérieur, également pertinent professionnellement.

## 4. Travaux réalisés et preuves

### 4.1 Clôture de la v1.2.2 (leçon sur les tags)
- Le tag `v1.2.2` avait d'abord été posé sur `d9f9a45`, révision sans le document de clôture. Il a été **déplacé une seule fois**, à titre exceptionnel (lab mono-utilisateur, aucune référence au tag dans les manifests) : `git tag -fa` puis `git push --force origin refs/tags/v1.2.2` (objet `a0759e1` remplacé par `b29cfa3`, commit `16a7432`).
- **Règle pour la suite :** le document de clôture est commité **avant** le tag, et un tag publié ne bouge plus.

### 4.2 Registre OCI de Gitea et publication de l'image
- **Constat :** registre actif (Gitea 1.27.0). `/v2/` et `/v2/_catalog` renvoient 401 avec `docker-distribution-api-version: registry/2.0` et une authentification Bearer sur `/v2/token`. L'URL `/api/packages/<owner>/container/` renvoie 404 : ce n'est pas une adresse d'API valide pour les images.
- **Docker côté WSL :** CA copiée dans `/etc/docker/certs.d/gitea.local/ca.crt` (644, root), identique au certificat de la CA du lab (`cmp` et empreinte contrôlées). Cette méthode évite de redémarrer le démon Docker, ce qui couperait les clusters Kind.
- **Jeton :** `registry-push-wsl`, permission **package : lecture et écriture** uniquement, créé dans l'interface de `gitea_admin`. Jamais collé dans le chat. `docker login` stocke l'identifiant **non chiffré** dans `~/.docker/config.json` (avertissement de Docker, accepté pour le lab).
- **Publication :** build depuis `~/lab/2048-repo` (arbre propre), tag `gitea.local/gitea_admin/2048:8c32cea`, 12 couches, digest de l'index OCI `sha256:c76fe9312b4e7dc20bd08117023d337c604274c4bc613b6690fc70200e892b7d` (taille de l'index : 856 octets ; image : 26 093 664 octets).
- **Stockage :** `/data/packages` sur le PVC de Gitea (25,1 Mo), 16 fichiers.
- **Lecture anonyme (confirmé) :** un `curl` simple sur le manifest renvoie 401 même si l'accès anonyme est permis (un registre OCI exige toujours un jeton Bearer). Avec un jeton anonyme obtenu sur `/v2/token` (188 caractères), le manifest répond **200**. `gitea_admin` est un compte public ; le dépôt `2048` est privé, mais le paquet est lisible anonymement.
- **Piège :** coller d'un bloc des commandes contenant `sudo` et `read` fait lire la saisie suivante par `sudo` (« password is empty ») ; le build a tourné, le push a échoué (`no basic auth credentials`). Exécuter ces commandes **séparément**.

### 4.3 Accès des nœuds workload au registre (diagnostic)
- **Résolution :** `gitea.local` était résolu en `127.0.0.1` dans les nœuds, ce qui désigne le nœud lui-même. L'origine est le fichier hosts Windows (confirmé par capture), relayé jusqu'aux nœuds par le résolveur ; le chemin exact (résolveur Docker `172.18.0.1` puis résolveur WSL) n'est pas prouvé. Aucune entrée n'existe dans le dépôt, le bootstrap, Kind ni `ExtraHosts` : rien à corriger à la source.
- **Chemin réseau :** depuis un nœud, `https://gitea.local/v2/` répond 401 en forçant la résolution vers l'IP du management (test avec `-k`, uniquement pour le routage).
- **containerd :** `config.toml` en `version = 2`, **sans `config_path`** : le kubelet (CRI) ne lit donc pas `/etc/containerd/certs.d`. `ctr --hosts-dir` lit `certs.d` à la demande, ce qui rend le test `ctr` **non représentatif** du chemin kubelet.
- **Tests manuels (dev puis prod) :**
  - `/etc/hosts` du nœud complété par `<IP management> gitea.local` ;
  - `/etc/containerd/certs.d/gitea.local/` avec `ca.crt` (certificat public) et `hosts.toml` (`capabilities = ["pull","resolve"]`, `ca = …`) ;
  - `ctr -n test-pull images pull --hosts-dir … <image>@sha256:c76fe93…` : pull terminé (24,9 Mo en 0,9 s), sans `x509` ;
  - ajout de `[plugins."io.containerd.grpc.v1.cri".registry] config_path = "/etc/containerd/certs.d"` et redémarrage de containerd : containerd migre la clé vers `io.containerd.cri.v1.images.registry` ; nœud `Ready` ; `crictl pull` réussi. Sur le prod, `crictl pull` sans couche en cache a réussi.
- **Fichier `/etc/hosts` d'un nœud :** monté par Docker, **perdu si le conteneur du nœud redémarre** ; `sed -i` y échoue (*Device or resource busy*).

### 4.4 Patch Kind, script rejouable et bootstrap (commit `fbd12b0`)
- **`clusters/workload-dev/kind-config.yaml` et `workload-prod/kind-config.yaml` :** ajout de `containerdConfigPatches` avec `config_path = "/etc/containerd/certs.d"`. Le management n'est pas modifié (seuls dev et prod téléchargent depuis Gitea).
- **`scripts/configure-workload-registry.sh` (77 lignes, mode 755) :**
  - **Phase 1, sans écriture :** inventaire lu depuis `clusters/workloads.tsv`, CA présente, non symbolique, non expirée ; IP du management calculée ; chaque nœud en marche et `config_path` actif dans `containerd config dump`. Un nœud non conforme bloque **tout** avant la moindre écriture.
  - **Phase 2, idempotente :** `/etc/hosts` réécrit sans `sed -i` (filtre de l'ancienne entrée puis `cat >`), copie du certificat public de la CA, écriture de `hosts.toml`, contrôles (résolution vers l'IP du management, CA identique, `hosts.toml` non vide).
  - Aucun redémarrage de containerd ; la clé de la CA n'est jamais lue.
  - **Rejouable seul** (par exemple après redémarrage d'un nœud) : `./scripts/configure-workload-registry.sh`.
- **`scripts/bootstrap-platform.sh` :** appel **une seule fois**, après la boucle de création des clusters workload et avant l'installation d'Argo CD (le script traite tous les nœuds de l'inventaire et refuserait si le prod n'existait pas encore).
- **Gardes avant destruction :**
  - une première version, placée dans le bloc `--plan`, **ne protégeait pas le PRA réel** (ce bloc sort par `exit 0` avant la lecture des arguments) ;
  - la garde définitive est dans le chemin réel du prévol, avant les contrôles de clé, de Git et de la CA : `[OK] Garde registre : script présent, config_path dans les kind-config workload`. Testée sur copies (script absent, patch retiré), puis sur les fichiers réels (`--preflight`, code 0).
- **Insertions de code :** par script Python avec **ancre unique** (rien n'est écrit si l'ancre est trouvée 0 ou 2 fois), sauvegardes `scripts/*.before-*` non suivies.

### 4.5 Manifests de 2048
**Arborescence (choix validé) :**

```text
applications/games/2048/
├── base/        namespace, deployment, service
└── overlays/
    ├── dev/     ingress (2048.dev.local) + digest
    └── prod/    ingress (2048.prod.local) + digest
argocd/applications/game-2048-dev.yaml
argocd/applications/game-2048-prod.yaml
```

- **Namespace par jeu** (`game-2048`, puis `game-snake`, `game-hextris`), label `app.kubernetes.io/part-of: games` pour le regroupement. Un namespace partagé aurait imposé une Application dédiée au namespace (un même objet `Namespace` ne peut pas être déclaré par plusieurs Applications).
- **Préfixe `game-`** : choix local, pas une convention reconnue. Un nom purement numérique pose problème (un Service doit commencer par une lettre ; `name: 2048` est lu comme un entier en YAML). Le dossier, l'hôte et l'image gardent `2048`.
- **Deployment :** 1 réplica, requests 10 mCPU / 16 MiB, limits 100 mCPU / 64 MiB, sondes readiness et liveness sur `/`, `seccompProfile: RuntimeDefault`, `automountServiceAccountToken: false`. Le modèle de whoami (3 réplicas sans requests/limits) n'est pas repris.
- **Digest dans l'overlay, pas dans la base :** dev et prod sont promus séparément ; la future CI n'aura qu'une ligne à modifier (`kustomize edit set image`).
- **Ingress :** classe `nginx`, hôtes `2048.dev.local` et `2048.prod.local`, HTTP.
- **Validation avant commit :** `kubectl kustomize`, `apply --dry-run=client --validate=strict` (4 objets passent), `--dry-run=server` (le Namespace passe ; les objets namespacés renvoient `namespaces "game-2048" not found` tant que le namespace n'existe pas : attendu). Le `diff` dev/prod ne montre que l'hôte de l'Ingress.
- **Commits :** `614baf2` (dev), puis `ae6aee0` (prod, après validation visuelle du dev), publiés séparément.
- **Hosts Windows :** `127.0.0.1 2048.dev.local` et `127.0.0.1 2048.prod.local` ajoutés (deux blocs identiques à ce jour : doublon sans effet).

### 4.6 Déploiement sur dev puis prod
- **Dev :** Application `Synced` puis `Healthy` (un `Progressing` initial, le temps que l'Ingress prenne son adresse), pod `1/1 Running`, `imageID` en `gitea.local/gitea_admin/2048@sha256:c76fe93…`. Événement `Pulled` en 171 ms (couches déjà présentes après les tests `ctr`/`crictl` : seule la résolution du manifest est prouvée).
- **Prod :** `Synced` / `Healthy`, pod `1/1 Running`, `Pulled` en 203 ms (même réserve).
- **Accès :** index `200 text/html`, `logic.mjs` `200 application/javascript` (le correctif MIME est dans l'image déployée), chemin par Traefik `200`. Jeu validé dans Chrome sur `2048.dev.local` et `2048.prod.local` (« Non sécurisé » attendu : HTTP).

**Mesures de consommation :**

| | Avant 2048 | Après 2048 | Pod 2048 |
|---|---|---|---|
| Nœud dev | 116 mCPU / 1 282 MiB | 181 mCPU / 1 304 MiB | 1 mCPU / 4 MiB |
| Nœud prod | 106 mCPU / 1 220 MiB | 170 mCPU / 1 248 MiB | 1 mCPU / 4 MiB |

- La mémoire des nœuds augmente d'environ 22 à 28 MiB. Le CPU des nœuds fluctue d'une mesure à l'autre (références v1.2.2 : dev 135 mCPU / 1 233 MiB, prod 144 mCPU / 1 228 MiB) ; le pod ne consomme que 1 mCPU, donc la variation de CPU n'est probablement pas imputable au jeu (**hypothèse**).

### 4.7 La sauvegarde couvre l'image (preuve avant PRA)
- `archive_gitea_data` exécute `tar -C /data -cf - .` sans exclusion : `/data/packages` est archivé.
- **Jeu `20261007-183256` :** 16 fichiers `packages` dans l'archive, 16 sur le PVC ; archive de 26 Mo ; `--validate` passe. Les noms `9d2a6b52…` (manifest du build) et `3624904f…` (couche vue au pull) sont présents.
- **La restauration** décompresse l'archive entière (`gzip -dc | tar -C /data -xf -`) dans un volume vérifié vide.
- **Limite :** `validate_game` n'exige que `./gitea.db`, `./gitea/conf/app.ini` et `./git/gitea-repositories/` (seuls les deux premiers sont contrôlés non vides), et `verify_restored_files` compare `gitea.db` et `app.ini`. **Un jeu sans l'image serait validé** ; la preuve de `packages/` est donc manuelle (comptage). Garde à ajouter : section 8.
- **Pendant la sauvegarde, le script met le déploiement Gitea à 0 réplica** : Gitea, donc son registre, est indisponible le temps de la copie, puis remis en service.

### 4.8 PRA v1.2.3 n°1
**Préparation :** dépôt sur `ae6aee0`, prévol code 0 (avec la garde registre), relevé de référence `~/.local/share/gitops-lab/pra/pra-v1.2.3-avant-20261007-183529.txt`. **Exécution :** `./scripts/bootstrap-platform.sh` sans argument, choix `2`, journal `~/.local/share/gitops-lab/logs/pra-v1.2.3-*.log` (0 `[STOP]`). Jeu `[SELECT] 20261007-183948`, pris par le bootstrap juste avant la destruction. Relevé après : `pra-v1.2.3-apres-20261007-184929.txt`.

| Contrôle | Avant | Après | Verdict |
|---|---|---|---|
| Empreinte de la CA | AD:AF:…:A3:A1:92 | AD:AF:…:A3:A1:92 | ✅ identique |
| Certificat Gitea | F7:F7:…:32:87 | 0D:9F:…:75:3D, émis par la CA | ✅ réémis |
| Certificat Argo CD | 0C:44:…:25:0C | 73:F6:…:A9:55, émis par la CA | ✅ réémis |
| Applications Argo CD | 25 Synced / Healthy | 25 Synced / Healthy | ✅ |
| Fichiers `packages` | 16 | 16 | ✅ |
| Manifest anonyme par digest `c76fe93…` | 200 | 200 | ✅ |
| `config_path` sur nœuds neufs | posé à la main | présent (patch Kind) | ✅ |
| `gitea.local`, CA, `hosts.toml` sur nœuds | posés à la main | présents, IP du management | ✅ (script du bootstrap) |
| Pods 2048 dev et prod | Running, digest `c76fe93…` | Running, digest `c76fe93…` | ✅ |
| Références Git (branches et tags) | sauvegarde `20261007-183948` | Gitea restauré | ✅ identiques |

- **Références Git :** `gitea_admin/2048` : `main` à `8c32cea` ; `gitea_admin/gitea-test` : `main` à `7748811`. La restauration est fidèle à la sauvegarde ; cela ne prouve pas que la sauvegarde contenait tout ce qui était attendu.
- **Commit poussé par le bootstrap :** `29842dd` (`renew workload registrations`), deux SealedSecrets de workloads (chiffrés).
- **Pull sur nœuds neufs :** 912 ms (dev) et 945 ms (prod) dans l'événement `Pulled`, sans couche en cache : **téléchargement des couches par le kubelet prouvé**, ce qui n'était pas le cas sur les nœuds de test.
- **Chrome :** `gitea.local` et `argocd.local` sans « Non sécurisé » et sans réimport de la CA.

### 4.9 Bannière de `bootstrap-workload.sh` (commit `7583b60`)
- `echo "Bootstrap Workload ${KIND_CLUSTER}"` : affiche le cluster traité (`gitops-dev`, `gitops-prod`). `KIND_CLUSTER` est déclarée avec `:?` avant la bannière, elle ne peut pas être vide.
- Poussée après le PRA n°1 (premier `git push` rejeté par une erreur interne de GitHub, passé au second essai, sans `--force`). **Rejouée au PRA n°2** : `Bootstrap Workload gitops-dev` puis `gitops-prod`.

### 4.10 PRA v1.2.3 n°2 (rejeu à l'identique)
**Préparation :** dépôt sur `7583b60`, prévol code 0, relevé `pra-v1.2.3b-avant-…`. **Exécution :** même commande, choix `2`, journal `pra-v1.2.3b-*.log` (0 `[STOP]`), jeu `[SELECT] 20261007-190623`. **Première sauvegarde prise sur un Gitea déjà restauré.**

| Contrôle | Avant | Après | Verdict |
|---|---|---|---|
| Empreinte de la CA | AD:AF:…:A3:A1:92 | AD:AF:…:A3:A1:92 | ✅ identique |
| Certificat Gitea | 0D:9F:…:75:3D | 8B:A0:…:7E:46, émis par la CA | ✅ réémis |
| Certificat Argo CD | 73:F6:…:A9:55 | 10:9D:F2:…:1A:44, émis par la CA | ✅ réémis |
| Applications Argo CD | 25 Synced / Healthy | 25 Synced / Healthy | ✅ |
| Fichiers `packages` | 16 | 16 | ✅ |
| Manifest anonyme par digest | 200 | 200 | ✅ |
| Nœuds : `config_path`, hosts, CA, `hosts.toml` | — | présents sur dev et prod | ✅ |
| Pods 2048 | Running | Running, digest `c76fe93…` | ✅ |
| Sauvegarde `20261007-190623` | — | 16 fichiers `packages`, références Git identiques à Gitea restauré | ✅ l'image survit à un second cycle |

- **Commit poussé par le bootstrap :** `857bf6b` (`renew workload registrations`) ; le dépôt local était déjà aligné sur `origin/main`.
- **Code retour final du bootstrap :** non relevé dans les échanges (le journal ne contient aucun `[STOP]`, et il se termine comme au PRA n°1).
- **Chrome :** un « Non sécurisé » rouge est apparu sur `gitea.local` après ce PRA, alors que `curl` renvoyait `verify=0` et que le certificat servi était émis par la CA. Il a **disparu après redémarrage complet de Chrome** (cause probable : état de la session précédente, **hypothèse**). Le premier affichage en `http://` renvoyait le 404 de Traefik (IngressRoute en `websecure` uniquement).

### 4.11 Chronologie du pull de 2048 au démarrage (quatre échantillons)
Au démarrage, les pods 2048 sont créés dès que les clusters workload sont enregistrés, **avant** que le bootstrap synchronise `gitea-external` (Certificate `gitea-local`, IngressRoute). Tant que ce certificat n'existe pas, Traefik présente son certificat par défaut ; le kubelet échoue (`x509: certificate is valid for …traefik.default, not gitea.local`, ce qui prouve que la CA est bien prise en compte), passe en `ErrImagePull` puis `ImagePullBackOff`, puis réessaie.

| | PRA 1 dev | PRA 1 prod | PRA 2 dev | PRA 2 prod |
|---|---|---|---|---|
| Pod créé (UTC) | 16:44:27 | 16:44:26 | 17:10:38 | 17:10:39 |
| Certificat `gitea-local` prêt | 16:45:56 | | 17:12:12 | |
| `Pulled` | 16:46:16 | 16:46:27 | 17:13:40 | 17:12:27 |
| Création du pod → `Pulled` | 1 min 49 s | 2 min 01 s | 3 min 02 s | 1 min 48 s |
| Certificat prêt → `Pulled` | 20 s | 31 s | 88 s | 15 s |

- **Cause confirmée :** le certificat `gitea-local` est créé environ 90 s après les pods (89 s au PRA n°1, 94 s au PRA n°2), et tous les premiers pulls ont échoué avant.
- **Délai non constant :** de 108 s à 182 s entre la création du pod et le pull réussi. L'écart de 88 s (PRA n°2, dev) est cohérent avec le back-off exponentiel du kubelet (**hypothèse non prouvée** : les messages de chaque `Failed` n'ont pas été relevés).
- **Réserve de lecture :** `kubectl get events` regroupe les répétitions ; `lastTimestamp` est la **dernière** occurrence. Mesurer depuis la création du pod (ligne 4) plutôt que depuis le premier `Failed`.
- **Rétablissement sans intervention** dans les quatre cas. Délai accepté en l'état pour le lab (point ouvert, section 8).

## 5. Historique Git gitops-lab

| Commit | Contenu | Remarque |
|---|---|---|
| 16a7432 | docs: add v1.2.2 capitalisation | porte le tag `v1.2.2` |
| fbd12b0 | feat(registry): give workload nodes access to the Gitea registry | patch Kind, script, bootstrap (115 lignes ajoutées) |
| 614baf2 | feat(games): deploy 2048 on workload-dev | 7 fichiers |
| ae6aee0 | feat(games): deploy 2048 on workload-prod | 3 fichiers |
| 29842dd | chore(pra): renew workload registrations | poussé par le bootstrap (PRA n°1) |
| 7583b60 | chore(bootstrap): show workload cluster name in bootstrap-workload banner | rejouée au PRA n°2 |
| 857bf6b | chore(pra): renew workload registrations | poussé par le bootstrap (PRA n°2) |
| *(commit de clôture)* | docs: add v1.2.3 capitalisation | porte le tag `v1.2.3` ; ajoute uniquement ce document |

- Les sauvegardes `scripts/*.before-*` restent **non suivies** : ne pas utiliser `git add .`.
- Fichiers `*:Zone.Identifier` (ajoutés par Windows au téléchargement) : à supprimer, jamais à commiter.

**Dépôt `gitea_admin/2048` (inchangé) :** `d673042` (initial), `22e9bd3` (implémentation originale, tests, Dockerfile), `8c32cea` (correctif MIME `.mjs`).

## 6. État de validation v1.2.3

| Critère | État | Preuve ou limite |
|---|---|---|
| Registre OCI de Gitea actif, lecture anonyme | **Validé** | `/v2/` 401, jeton anonyme puis manifest 200 |
| Image publiée, référencée par digest | **Validé** | `sha256:c76fe93…`, 16 fichiers `packages` |
| Accès des nœuds au registre (hosts, CA, `config_path`) | **Validé** | PRA n°1 et n°2, script rejouable |
| Garde de prévol (patch Kind, script) | **Validé** | tests sur copies, prévol réel, deux PRA |
| 2048 en ligne dev et prod | **Validé** | Applications Healthy, jeu testé dans Chrome |
| Image restaurée avec la sauvegarde Gitea | **Validé** | 16 fichiers, manifest 200, pods Running après PRA |
| Image préservée sur une sauvegarde d'un Gitea restauré | **Validé** | jeu `20261007-190623` |
| Téléchargement des couches par le kubelet sur nœuds neufs | **Validé** | `Pulled` en 912 / 945 ms (PRA n°1) |
| Références Git de Gitea restaurées | **Validé** | identiques à la sauvegarde (deux PRA) |
| CA identique, certificats réémis, confiance clients sans réimport | **Validé** | deux PRA |
| PRA multicluster rejoué deux fois | **Validé** | sections 4.8 et 4.10 |
| HTTPS de 2048 | **Non fait** | HTTP, comme whoami |
| Garde sur `packages/` dans la validation de sauvegarde | **Non fait** | preuve manuelle |
| Tag `v1.2.3` | **Posé sur le commit de clôture** | section 4.12 |

### 4.12 Clôture et publication
- Dépôt local aligné sur `origin/main` (`857bf6b`) avant la clôture.
- Ce document est ajouté par un commit dédié (sans les `scripts/*.before-*`), puis le tag annoté `v1.2.3` est posé sur ce commit et publié **sans `--force`**.
- Vérification : `git ls-remote --tags origin 'v1.2.3*'` ; le pointeur `^{}` désigne le commit de clôture, dont le parent est `857bf6b`.

## 7. Points de vigilance et savoir-faire

**Commandes et exécution**
- Exécuter séparément les commandes qui attendent une saisie (`sudo`, `read`).
- Insérer du code dans un script par ancre unique ; sauvegarde `.before-*` ; `bash -n` et `git diff --check`.
- Un test de garde sur copie temporaire (le script calcule sa racine depuis son propre emplacement) ne prouve pas la garde réelle : rejouer `--preflight` sur les fichiers réels.
- `kubectl --dry-run=server` ne valide pas un objet namespacé dans un namespace inexistant.
- `kubectl get events` regroupe les répétitions (`lastTimestamp` = dernière occurrence).

**Réseau, containerd, registre**
- Un registre OCI renvoie toujours 401 sans jeton Bearer, même en lecture anonyme : tester via `/v2/token`.
- Le CRI de containerd (kubelet) ne lit `certs.d` que si `config_path` est renseigné ; `ctr --hosts-dir` n'est pas représentatif.
- `/etc/hosts` d'un nœud Kind : réécriture par `cat >` (pas de `sed -i`), perdu au redémarrage du nœud : relancer `configure-workload-registry.sh`.
- Les nœuds workload ont besoin d'un Gitea **restauré et de son certificat** pour démarrer 2048 ; sans Gitea, 2048 reste en `ImagePullBackOff`.

**Sauvegarde et PRA**
- La sauvegarde met Gitea à 0 réplica le temps de la copie (registre indisponible).
- La validation ne contrôle pas `packages/` : comparer le nombre de fichiers `packages` de l'archive et du PVC.
- Après un PRA, un « Non sécurisé » dans Chrome alors que `curl` renvoie `verify=0` : redémarrer complètement Chrome avant de chercher ailleurs. Saisir `https://` en entier (IngressRoute Gitea en `websecure` uniquement).

**Git**
- Un push rejeté par une erreur interne de GitHub se retente ; ne jamais réécrire l'historique pour une panne.
- Le prévol refuse un `main` local différent de `origin/main` et un index non propre : commiter et publier avant tout PRA.
- Ne plus déplacer un tag publié (une seule exception, v1.2.2).

**Sécurité**
- Ne jamais afficher ni commiter la clé de la CA, un Secret complet, un kubeconfig, un jeton ou la phrase de passe.

## 8. Feuille de route et points ouverts

**Points ouverts**
1. **Garde sur `packages/`** dans `validate_game` (et éventuellement `verify_restored_files`) : exiger au moins un fichier. Elle rejetterait les anciens jeux sans image.
2. **Ordre de démarrage 2048 / Gitea :** les pods attendent environ 90 s le certificat `gitea-local`, puis le back-off du kubelet (108 à 182 s mesurés). Pistes (non essayées) : synchroniser `gitea-external` plus tôt, ou retarder l'enregistrement des Applications 2048. Accepté pour le lab.
3. **HTTPS de 2048 :** les IngressRoutes des workloads sont en HTTP et cert-manager n'est pas installé sur les workloads. À traiter comme jalon séparé.
4. **Mot de passe admin Argo CD :** signalé comme compromis par Chrome en v1.2.2 ; à changer via le mécanisme de hash du bootstrap, puis à faire survivre à un PRA.
5. **Jeton `registry-push-wsl` et identifiants Docker non chiffrés** (`~/.docker/config.json`) : révoquer ou renouveler le jeton, ajouter un gestionnaire d'identifiants. La CI aura son propre jeton.
6. **Lecture anonyme du registre :** acceptable pour le lab (images publiques de jeux) ; à revoir pour toute image privée (`imagePullSecret` en SealedSecret).
7. **Image de base :** la sortie du build affiche un digest résolu pour `nginx:stable-alpine` ; cela ne prouve pas que le Dockerfile l'épingle. À vérifier (la v1.2.2 notait ce tag comme mobile).
8. **Fichier hosts Windows :** deux blocs identiques `2048.*.local` à dédoublonner ; une ligne résiduelle `172.18.255.200 ingress.workload-dev.lab.local` (IP du LB **prod** sous un nom « dev ») a été observée sur une capture, sans effet sur la suite.
9. **Renouvellement automatique des certificats** (cert-manager) : non observé ; échéance vers janvier 2027.
10. **`selfsigned-cluster-issuer`** : toujours déclaré, plus utilisé ; retrait à décider après vérification qu'aucune ressource ne le référence.
11. **`gitea-test`** : conservé comme dépôt témoin ; à nettoyer seulement après remplacement de son rôle dans la recette.
12. **Snake et Hextris :** dépôts non créés ; code original ou provenance et licence claires ; même modèle (`applications/games/<jeu>`, namespace `game-<jeu>`).

**Étape suivante : CI de modification et de livraison vers les clusters de workload.** Pistes à valider, rien d'installé :
- choix du runner (Gitea Actions avec `act_runner`, ou autre) et son emplacement ;
- jeton de publication distinct de celui du poste, limité au paquet concerné ;
- publication d'une image par commit, puis mise à jour du digest dans l'overlay **dev** (`kustomize edit set image`), validation, puis promotion vers prod par un commit distinct ;
- enregistrement du runner et des secrets de la CI à faire survivre au PRA ;
- tenir compte de l'indisponibilité de Gitea pendant la sauvegarde.

## 9. Dépendances et risques
- **Gitea est désormais sur le chemin de démarrage de 2048** (image) en plus d'héberger le code. Une perte de la sauvegarde Gitea ou du PVC prive les workloads de leur image au prochain pull ; l'image est reconstructible depuis `gitea_admin/2048` (sauvegardé avec le reste).
- **Copie cloud de la CA :** en cas de perte du poste, récupérer l'archive sur Drive et la déchiffrer avant le bootstrap (accès au compte Google et phrase de passe).
- **Clients de la CA :** WSL, Windows (`CurrentUser\Root`) et désormais les nœuds dev et prod (certificat public dans `certs.d`).
- **Retrait de la confiance :** supprimer le certificat des nœuds par recréation du cluster (ou du fichier `certs.d`), le fichier d'Ubuntu puis `update-ca-certificates`, et le certificat `11ACB678…` de `CurrentUser\Root`.
- **Dépendances externes du PRA :** GitHub, charts, images publiques (nginx de base). Une indisponibilité de GitHub peut rejeter un push (observé une fois, résolu au second essai).
- **Limite inotify :** 512 relevée au prévol ; éviter de créer un cluster Kind supplémentaire en dehors du PRA.

## 10. Critères de clôture de v1.2.3

| Critère | État |
|---|---|
| Registre Gitea actif, image publiée et référencée par digest | ✅ Atteint |
| Nœuds workload : accès au registre posé par le bootstrap (patch Kind + script) | ✅ Atteint |
| Garde de prévol testée sur fichiers réels | ✅ Atteint |
| 2048 en ligne sur dev puis prod, jeu validé dans Chrome | ✅ Atteint |
| Image présente dans la sauvegarde et restaurée (16 fichiers, manifest 200) | ✅ Atteint |
| PRA rejoué deux fois : CA identique, certificats réémis, 25 Applications Healthy, pods 2048 Running | ✅ Atteint |
| Pull des couches par le kubelet sur nœuds neufs | ✅ Atteint |
| Références Git de Gitea identiques à la sauvegarde | ✅ Atteint |
| Aucun secret dans Git ni dans ce document | ✅ Atteint |
| Tag `v1.2.3` posé sur la révision qui contient ce document | ✅ Atteint (voir 4.12) |

**Version clôturée.** Point de reprise : choix du runner de la CI, en gardant en tête les points ouverts 1 à 4.

## Sources de référence
- Capitalisations v1.2.0, v1.2.1 et v1.2.2.
- Preuves v1.2.3 : sorties de commandes, captures (Chrome, Argo CD, Gitea) et relevés avant/après des deux PRA du 7 octobre 2026 (`~/.local/share/gitops-lab/pra/`).
- Documentation officielle : Kubernetes, containerd, Gitea, Argo CD, cert-manager, Kustomize. Elle décrit les outils mais ne prouve pas l'état du lab.
