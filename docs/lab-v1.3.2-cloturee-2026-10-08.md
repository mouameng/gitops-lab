## GitOps Lab — Capitalisation v1.3.2 : DNS du cluster management pour gitea.local et inventaire des éléments hors source de vérité intégré au prévol

**Statut : v1.3.2 clôturée le 8 octobre 2026**, sous réserve du dernier contrôle de publication (section 10). Deux chantiers ont été menés. Le premier est un **DNS dans Kubernetes** : le CoreDNS du cluster management répond désormais `gitea.local` avec le Service Traefik, au lieu de `127.0.0.1`. Cela débloque l'accès au registre OCI de Gitea depuis les pods, le démon Docker imbriqué et les futurs conteneurs de jobs CI. Le second est un **inventaire versionné** (`scripts/external-deps.tsv`) des éléments nécessaires au PRA qui ne sont pas dans Gitea, contrôlé en lecture seule par `scripts/check-external-deps.sh` depuis le prévol. Le PRA multicluster a été rejoué **deux fois** : l'entrée DNS a été rejouée automatiquement sur le cluster reconstruit à chaque fois, et la ClusterIP de Traefik, différente à chaque reconstruction, n'a pas affecté la résolution. Un point reste **non expliqué** et non bloquant : Traefik est vu `Degraded` pendant environ deux minutes après chaque PRA, alors que son pod est prêt (section 6).

**Révision de référence :** le tag v1.3.2 désigne la révision qui **apporte la version finale de ce document** dans Gitea. Cette révision a pour parent `43bfd9b`, qui avait publié par erreur une version antérieure du même fichier (sans le PRA n°2, 358 lignes) ; elle remplace ce fichier, sans autre modification. `43bfd9b` est lui-même enfant du commit du cadrage v1.3.2 (`8fb97a1`, documentation seule), enfant du commit du PRA n°2, `8f61caf` (chore(pra): renew workload registrations). Le hash du commit de clôture n'est pas inscrit ici : utiliser `git rev-parse 'v1.3.2^{commit}'`.

**Complète :** `gitops-lab-v1.3.2-cadrage-dns-2026-10-08.md` (cadrage et décision d'architecture, écrit avant l'implémentation ; son statut « aucune modification du lab » est daté et reste tel quel) et `gitops-lab-v1.3.1-cloturee-2026-10-08.md` (tag figé). Le contenu des versions précédentes reste acquis et n'est pas repris en détail.

**Changement de feuille de route :** le document v1.3.1, publié et tagué, annonce encore « CI Gitea Actions = v1.3.2 ». Selon la règle « tag publié = figé », il reste tel quel. La CI est décalée (section 8). Cet écart est noté ici.

**Périmètre :** nommage et option DNS, relevé de CoreDNS, test TLS vers le registre depuis un conteneur imbriqué, script `configure-management-dns.sh`, inventaire hors source de vérité (relevé, nettoyage, manifeste, script de contrôle), deux patchs du bootstrap, deux PRA.

**Convention de lecture :**
- **confirmé** : sortie ou capture rapportée dans les échanges ;
- **déduit** : conséquence logique d'éléments confirmés, non testée directement ;
- **hypothèse** : explication cohérente avec les observations, non prouvée ;
- **à valider** : pas encore démontré.

Une commande citée sans résultat ne vaut pas preuve de son exécution.

### 1. Synthèse

Le diagnostic de départ (cadrage) : `gitea.local` résolvait vers `127.0.0.1` pour tout ce qui passe par le DNS du cluster, parce que l'entrée du hosts Windows est relayée par WSL, puis par le DNS Docker, puis par CoreDNS. C'est juste pour le navigateur, faux pour un pod. Une entrée `hostAliases` n'aurait corrigé que le démon Docker, pas les conteneurs de jobs, qui interrogent le DNS du cluster.

**Décisions :**
- **Option 2 maintenant, option 3 plus tard.** Le DNS du lab dans Kubernetes est la référence pour les pods, le DinD, le runner et les jobs. Le DNS central (Windows, WSL, Docker, Kind) est repoussé avec la PKI.
- **Le hosts Windows est conservé** pour le navigateur et WSL. Le bootstrap ne le modifie pas (droits administrateur, PRA rejoué régulièrement). Il est seulement **contrôlé** par le prévol, en `[WARN]`.
- **On garde `gitea.local`** et les six autres noms `.local`. Le choix d'une zone définitive est reporté à la v1.4.0 (section 3.2).
- **Une ligne `rewrite` vers le Service Traefik**, plutôt qu'une IP écrite en dur : `rewrite name exact gitea.local traefik.traefik.svc.cluster.local answer auto`. La ClusterIP change à chaque PRA, le nom du Service non.
- **Seul le management est modifié.** Dev et prod restent identiques : aucun pod de ces clusters n'a besoin de `gitea.local` aujourd'hui. Les nœuds workload ont déjà l'entrée côté containerd (`configure-workload-registry.sh`).
- **Un script dédié et rejouable** (`configure-management-dns.sh`), appelé par le bootstrap, plutôt qu'une logique dans `bootstrap-platform.sh`. Il insère une ligne dans le Corefile **existant**, sans jamais le remplacer, et restaure l'état précédent si CoreDNS ne redémarre pas.
- **Pas d'Argo CD pour cette ConfigMap :** elle appartient à kubeadm, et la gérer par GitOps créerait un conflit et un risque d'œuf et de poule.
- **L'inventaire hors source de vérité est un manifeste versionné**, sans déplacer aucun fichier : les chemins sont écrits en dur dans les scripts, et le découpage XDG existant est déjà cohérent.

**État au 8 octobre 2026 :**
- `gitea.local` résout vers la ClusterIP de Traefik depuis le management. Un conteneur imbriqué atteint `https://gitea.local/v2/` sans `--add-host`, avec le TLS validé par la CA du lab.
- Inventaire : 26 entrées (8 couvertes par une garde existante, 3 contrôles manuels, 15 évalués). `check-external-deps.sh --check` donne `global=OK`. Le prévol l'appelle.
- **PRA rejoué deux fois** : l'entrée DNS a été appliquée par le bootstrap à chaque fois, et Gitea et GitHub ont reçu les commits de PRA sans intervention (`d0e6d4d`, puis `8f61caf`).
- **Au PRA n°2, les 25 Applications Argo CD ont convergé vers Synced/Healthy sans intervention.** Traefik y est resté `Degraded` pendant 2 min 20 s alors que son pod était prêt. Au PRA n°1, Traefik avait aussi été vu `Degraded` et rafraîchi à la main (section 6).
- **Reporté (section 8) :** CI Gitea Actions, DNS central, PKI, deuxième nettoyage, confiance du démon Docker dans la CA.

### 2. Architecture de référence

#### 2.1 Chaîne de résolution de gitea.local

Avant la v1.3.2 (confirmé par le cadrage) :
```
Conteneur de job / pod
  -> CoreDNS du management (10.96.0.10), aucune entrée gitea.local
  -> forward vers /etc/resolv.conf du nœud Kind : DNS intégré de Docker (172.18.0.1)
  -> résolveur de WSL (10.255.255.254)
  -> Windows : fichier hosts, 127.0.0.1 gitea.local   <- adresse inutilisable dans un pod
```

Depuis la v1.3.2, pour le management :
```
Pod / DinD / conteneur de job
  -> CoreDNS du management (10.96.0.10)
       rewrite name exact gitea.local -> traefik.traefik.svc.cluster.local
       (puis kubernetes, forward, cache, comme avant)
  -> Service traefik (ClusterIP, ports 80 et 443)
  -> pod Traefik (hostPort 80 et 443 du nœud)
```

#### 2.2 Qui obtient quelle adresse

| Demandeur | Adresse de gitea.local | Mécanisme |
|---|---|---|
| Navigateur Windows, WSL | 127.0.0.1 | hosts Windows (inchangé, contrôlé par le prévol) |
| Nœuds workload (containerd) | 172.18.0.2 | `configure-workload-registry.sh` (inchangé, v1.2.3) |
| Pods, DinD, jobs du management | ClusterIP du Service Traefik | `rewrite` dans le CoreDNS du management (**nouveau**) |
| Pods de dev et prod | 127.0.0.1 (déduit : Corefile par défaut, relayé par le hosts Windows) | inchangé ; décision reportée (section 8) |

#### 2.3 Éléments relevés sur le terrain (confirmé, 8 octobre)

| Élément | Valeur |
|---|---|
| CoreDNS | v1.14.6, 2 réplicas, Corefile **identique** sur management, dev et prod, sans personnalisation |
| Auteur de la ConfigMap `coredns` | `kubeadm` seul (dernière écriture 2026-10-08 09:38:08Z) |
| Applications Argo CD ciblant `kube-system` | seulement les trois `metrics-server`, aucune référence à CoreDNS dans le dépôt |
| Adresses des nœuds Kind | management 172.18.0.2, dev 172.18.0.3, prod 172.18.0.4 |
| Traefik | `hostNetwork=false`, ports de conteneur 8000 et 8443 publiés en hostPort 80 et 443 ; le fichier Kind du management mappe 80 et 443 vers l'hôte |
| Services `workload-dev` et `workload-prod` | `ExternalName` vers `gitops-dev-control-plane` et `gitops-prod-control-plane` |

#### 2.4 Ordre du bootstrap (ajouts v1.3.2)

```
Prévol (aussi exécuté par --preflight)
  ... contrôle du dépôt de secours GitHub (v1.3.1)
  [NOUVEAU] check-external-deps.sh --check : 0 et 2 = on continue, 1 et 3 = STOP avant le menu
  [NOUVEAU] configure-management-dns.sh --render-check : STOP si en échec (aucun accès au cluster)
  ... garde « fichiers Git suivis », destinations Git, hash Argo CD, paire CA (inchangées)
PRA
  ... création des 3 clusters, configure-workload-registry.sh (inchangé)
  [NOUVEAU] configure-management-dns.sh --apply : en cas d'échec, [WARN] et le PRA continue
  ... installation d'Argo CD, CA, Sealed Secrets, restauration Gitea, Root App (inchangés)
```

### 3. Travaux réalisés et preuves

#### 3.1 Options DNS étudiées (avant décision)

| Variante CoreDNS | Avantage | Limite |
|---|---|---|
| Plugin `hosts` (entrées inline) | Le plus simple ; couvre tous les pods | IP écrite en dur, à injecter ; un enregistrement par nom |
| Plugin `rewrite` vers un nom de Service | Pas d'IP ; la cible suit le cluster | Rien de réutilisable côté Windows |
| Zone dédiée (fichier de zone ou CoreDNS séparé) | Jokers, structure de zone ; réutilisable en v1.4.0 | Plus de composants ; il faut décider qui interroge qui |

**Retenu :** `rewrite` vers le Service Traefik. Le plugin `hosts` avec `172.18.0.2` est resté la solution de repli, non utilisée.

#### 3.2 Nommage : gitea.local ou *.lab.local

- **`.local` est réservé au DNS multicast (RFC 6762)** : tout nom en `.local` est traité comme lié au lien local. Cela reste tolérable pour un lab. **`lab.local` ne règle pas ce point** : le suffixe reste `.local`.
- **`.internal`** a été réservé par ICANN (résolution du Conseil, juillet 2024) pour un usage privé et ne sera jamais délégué à la racine. C'est un candidat de suffixe définitif. Source secondaire (ICANNWiki) ; à confirmer lors de la v1.4.0.
- **Coût d'un renommage, plus large que dans le cadrage :** certificat `gitea-local` (cert-manager), `server.DOMAIN` et `ROOT_URL` de Gitea, `hosts.toml` et CA des nœuds workload, 17 références de dépôt (selon l'URL utilisée), **7 noms du hosts Windows** (`argocd`, `traefik`, `gitea`, `whoami.dev`, `whoami.prod`, `2048.dev`, `2048.prod`), leurs Ingress et leurs certificats. Le nom d'hôte fait aussi partie du chemin des images (`gitea.local/gitea_admin/2048@sha256:…` dans l'historique du Deployment 2048) : les overlays dev et prod seraient touchés (déduit).
- **Décision :** garder les noms actuels pour ce livrable, et ne renommer **qu'une fois**, en v1.4.0, vers le suffixe définitif choisi avec la PKI.

#### 3.3 Compatibilité avec un DNS complet incluant Windows (analyse)

- Les noms, les enregistrements et les certificats se réutilisent. À refaire : la configuration propre à CoreDNS Kubernetes, et le traitement des postes clients.
- **Le sujet réel est le split-horizon.** Windows doit recevoir `127.0.0.1`, alors que les pods et les nœuds doivent recevoir une adresse du cluster. Un DNS central devra répondre selon le demandeur (le plugin `view` de CoreDNS est une piste, **non vérifiée** sur cette version). L'entrée du CoreDNS de Kubernetes ne disparaîtra donc pas forcément.
- **WSL :** le DNS tunneling est activé par défaut depuis WSL 2.2.1. Cela conforte la déduction du cadrage selon laquelle WSL suit le hosts Windows (non testée directement).
- **À tester avant de s'engager :** le comportement de Windows face à un nom `.local` servi par un DNS unicast (délais ou résolution mDNS prioritaire).

#### 3.4 Inventaire des éléments hors source de vérité

**Relevé (lecture seule, confirmé) :**
- `~/.config/gitops-lab/` (700) : jeton Gitea, échéance du PAT, CA (certificat et clé en 600, **empreintes de clé publique identiques**), deux clés Sealed Secrets, hash admin Argo CD, archives de la CA, dossiers de candidats et de sauvegardes de registration.
- `~/.local/share/gitops-lab/` : jeux de sauvegarde Gitea et journaux.
- Le hosts Windows contient 7 noms `.local` vers `127.0.0.1`, **en fins de ligne CRLF** (28 lignes avec `\r`) : le contrôle doit retirer les `\r`.
- Clé Sealed Secrets : le cluster management n'a qu'**une clé active**, `sealed-secrets-keyx9rjr`, qui porte le même nom que le fichier utilisé par le bootstrap. `sealed-secrets-key.yaml` contient une autre clé (`7sctf`), non active.
- Le manifeste `pra-isolated/argocd-v3.5.3-install.yaml`, que l'on pensait obsolète, **est utilisé par le bootstrap**, qui vérifie son SHA-256 (`7efe2d6b…`) au prévol. Il est conservé.

**Nettoyage réalisé (confirmé par la sortie des commandes) :**
- 14 fichiers `scripts/*.before-*` et un `…cadrage…:Zone.Identifier` (aucun n'était suivi par Git) ;
- 3 sauvegardes de scripts hors dépôt, un `.before-server-fix`, un `.before-tag-fix` ;
- 25 entrées de `pra-isolated`, **sauf** le manifeste Argo CD ;
- à la racine du dépôt, le binaire `kubeseal`, son tarball et `LICENSE` (doublons de `/usr/local/bin/kubeseal` 0.32.0, environ 81 Mo).

Vérification après nettoyage : le SHA du manifeste est conforme, `git status` ne montre plus que le cadrage, et le prévol finit en code 0.

**Décision de ne pas déplacer les fichiers :** les chemins sont écrits en dur dans le bootstrap, dans `configure-workload-registry.sh` et dans les scripts de jeton ; le découpage XDG existant (`~/.config` pour les secrets, `~/.local/share` pour les sauvegardes et journaux) est cohérent ; `~/lab` est un mauvais emplacement pour des secrets (risque de `git add` accidentel) ; `/mnt/c` ne respecte pas le mode 600. Un déplacement éventuel serait fait en v1.4.0, avec une variable de base (`GITOPS_LAB_HOME`) dont la valeur par défaut serait le chemin actuel.

**Le manifeste `scripts/external-deps.tsv` :**
- 6 colonnes séparées par des tabulations : identifiant, niveau (`BLOCK`, `WARN`, `INFO`), contrôle, cible, attendu, note. Ne contient jamais de secret.
- Contrôles : `covered` (garde déjà dans le bootstrap ; le script vérifie que le fragment de message existe encore dans `scripts/*.sh`), `manual`, `path`, `file-newer`, `hosts`, `ca-trust`, `disk-free`, `cmd`, `argocd-repos`.
- 26 entrées : **8 couvertes** (clé Sealed Secrets, manifeste Argo CD, certificat et clé de la CA, hash admin Argo CD, jeton Gitea, échéance du PAT, sauvegardes Gitea), **3 manuelles** (copie hors machine de la CA et de sa passphrase, copie hors machine de la clé Sealed Secrets, PAT dans le gestionnaire de mots de passe), **15 évaluées**.
- Ajouter un élément hors Git = ajouter une ligne dans le même commit.

**Le script `scripts/check-external-deps.sh` :**
- Modes `--list`, `--check`, `--check --offline` (saute les tests réseau). Lecture seule, aucun secret affiché.
- Codes retour : 0 OK, 2 avertissement, 3 critique, 1 manifeste invalide ou erreur d'usage. Un manifeste invalide (niveau inconnu, mauvais nombre de colonnes, identifiant en double) est refusé.
- Les noms du hosts Windows : 7 entrées vérifiées avec leur adresse ; fichier illisible = `[INFO]` unique, sans arrêt.
- Premier `--check` réel : `global=OK ok=21 warn=0 crit=0` (14 avec `--offline`, soit 21 moins les 7 dépôts de charts externes).
- **Limite :** le test de joignabilité d'un dépôt de charts vérifie que l'hôte répond (HTTP 404 normal sur la racine d'un `github.io`), pas que l'index du chart est servi.
- Empreintes de livraison : script `cbc5c868a6221ece…`, manifeste `ddafa1645ebb3318…`.

**Intégration au prévol (patch à ancre unique, 22 lignes ajoutées, 0 supprimée) :**
- Les codes 0 et 2 laissent continuer ; les codes 1 et 3 arrêtent avant le menu PRA, donc avant toute destruction. Un script absent ou non exécutable est un `[STOP]`.
- Variable `EXTERNAL_DEPS_OFFLINE=1` pour sauter le réseau.
- Empreinte du bootstrap : `6e35d359…` (v1.3.1) -> `455d0d9c…`.
- Test A (hosts sans `2048.prod.local`) : deux `[WARN]`, `Prévol terminé`, code 0. Test B (manifeste invalide) : deux `[STOP]`, pas de `Prévol terminé`, code 1.

#### 3.5 Test TLS vers le registre depuis un conteneur imbriqué (avant tout changement de DNS)

Dans le pod jetable `dind-test` du management (Docker 29.8.2, overlayfs, cgroups v2), avec la CA **publique** du lab copiée dans le pod (empreintes identiques des deux côtés) et l'image `curlimages/curl:latest` (non épinglée, test seulement) :

| Route | Résultat (confirmé) |
|---|---|
| `--add-host gitea.local:172.18.0.2` (hostPort du nœud) | `http=401 verify=0`, 7,6 ms |
| `--add-host gitea.local:<ClusterIP du Service Traefik>` | `http=401 verify=0`, 5,5 ms |

Le 401 est la réponse attendue de `/v2/` sans authentification. `verify=0` signifie que le certificat est validé par la CA du lab. **Le chemin hostPort fonctionne donc depuis un pod du management** (le doute du cadrage est levé). Ce test n'utilisait pas le DNS.

#### 3.6 Script configure-management-dns.sh

**Principe :** insère une ligne `rewrite` avant `kubernetes cluster.local` dans le Corefile existant, avec la même indentation. Seule la clé `data.Corefile` est patchée.

| Mode | Effet |
|---|---|
| `--render-check` | Outils et transformation d'un Corefile de référence ; **aucun accès au cluster** (utilisé au prévol) |
| `--preflight` (défaut) | Lit le cluster, affiche le diff, dry-run serveur ; aucune écriture |
| `--apply` | Sauvegarde, patch, redémarrage de CoreDNS, contrôle ; idempotent |
| `--status` | Code 0 si l'entrée est en place, 2 sinon |
| `--rollback [fichier]` | Restaure le Corefile d'une sauvegarde (par défaut la plus récente) |

**Sécurités :**
- **Corefile non reconnu = `[STOP]` sans rien écrire** (nom déjà présent sous une autre forme, pas de plugin `kubernetes`, deux serveurs, autre cible).
- **Sauvegarde avant action :** `~/.local/share/gitops-lab/dns-backups/` (700, fichiers en 600).
- **Le dry-run serveur ne valide que l'objet ConfigMap, pas la syntaxe du Corefile.** C'est le redémarrage des pods qui la valide : si CoreDNS ne redémarre pas, le script restaure automatiquement le Corefile précédent (`[ROLLBACK]`).
- Variables : `MGMT_CONTEXT`, `DNS_NAME`, `DNS_TARGET`, `DNS_BACKUP_DIR`, `DNS_ROLLOUT_TIMEOUT`.

**Preuves sur le cluster réel (confirmé) :**
- `--render-check` : une ligne insérée, aucune modifiée ni supprimée, idempotent, quatre refus conformes.
- `--preflight` : diff d'une seule ligne, dry-run serveur accepté, rien d'écrit.
- `--apply` : sauvegarde `coredns-kind-gitops-management-20261008-191542.json`, redémarrage sans `[ROLLBACK]` (CoreDNS v1.14.6 accepte la ligne `rewrite`).
- Depuis `dind-test` : `gitea.local` -> `10.96.180.79` (au lieu de `127.0.0.1`) ; `kubernetes.default` -> `10.96.0.1` et `github.com` -> `140.82.121.3` répondent normalement ; **aucune adresse AAAA** n'est affichée (cohérent avec un Service IPv4 seul, déduit).
- Conteneur imbriqué **sans `--add-host`** : `http=401 verify=0 ip=10.96.180.79`.
- Dev et prod : 0 ligne `rewrite`.
- Empreinte de livraison : `b3ffd0040d295a31…`.

**Testé seulement contre un faux `kubectl` :** échec de redémarrage avec retour arrière automatique, dry-run refusé, patch refusé, ConfigMap absente, entrées invalides, rollback sans sauvegarde. Ces cas n'ont pas été rejoués sur un vrai cluster.

#### 3.7 Intégration du DNS au bootstrap (patch à deux ancres, 22 lignes ajoutées, 0 supprimée)

- **Prévol :** après le bloc des éléments hors source de vérité, le script doit exister et être exécutable, puis `--render-check` doit passer, sinon `[STOP]` avant le menu.
- **Reconstruction :** juste après `configure-workload-registry.sh`, `--apply` sur `kind-gitops-management`. **Un échec est un `[WARN]` et non un arrêt** : à ce stade les clusters sont déjà recréés, et l'entrée ne sert qu'à la CI. Inconvénient accepté : un échec peut passer inaperçu dans un long journal, et la CI échouerait alors avec une erreur de résolution. Le message indique la commande à rejouer.
- Empreinte du bootstrap : `455d0d9c…` -> `f100f89c…`. Le bloc `--plan` du bootstrap n'a pas été mis à jour (cosmétique, comme en v1.3.1).
- Commits : `011f005` (inventaire), `10ad6b7` (contrôle des éléments hors source de vérité au prévol), `71c96d7` (script DNS), `0e807e8` (branchement du DNS au bootstrap).

#### 3.8 PRA v1.3.2 n°1

- Prévol conforme (toutes les gardes, dont les deux nouvelles). Jeu Gitea frais : **20261008-192327**. Choix 2, destruction puis reconstruction des 3 clusters.
- **Ordre observé dans le journal (confirmé) :** configuration du registre des nœuds workload, puis sauvegarde `coredns-kind-gitops-management-20261008-192554.json`, redémarrage de CoreDNS sans `[ROLLBACK]`, `[OK] DNS du management : gitea.local -> Service Traefik`, **et ensuite seulement** l'installation d'Argo CD.
- Commit du PRA `d0e6d4d` (chore(pra): renew workload registrations), publié dans Gitea par `gitea-publish.sh` ; **recopié sur GitHub par le mirror sans intervention** (les deux dépôts à `d0e6d4d8`, `global=OK`).
- **Après le PRA (confirmé) :**
  - `--status` : entrée DNS en place, code 0 ; deux pods CoreDNS en cours d'exécution.
  - **ClusterIP de Traefik : `10.96.251.119`**, différente de l'ancienne (`10.96.180.79`). `gitea.local` renvoie cette nouvelle adresse depuis un pod jetable : le `rewrite` vise bien le nom du Service.
  - Conteneur jetable `curl` avec la CA du lab, sans `--add-host` : `http=401 verify=0 ip=10.96.251.119`. Le message `couldn't attach to pod` est sans conséquence.
  - Inventaire (`--offline`) : `global=OK`. Dev et prod : 0 ligne `rewrite`.
- **Écart avec les PRA précédents :** au premier décompte, les Applications Argo CD étaient **22 Synced/Healthy, 2 Synced/Progressing, 1 Synced/Degraded** (25 en tout). Traefik était l'Application vue `Degraded` ; elle a été rafraîchie à la main (hard refresh), puis le décompte est passé à **25 Synced/Healthy**, sans ressource non saine ni pod non prêt sur les trois clusters. Les noms des deux autres Applications n'ont pas été relevés, et on ne sait pas si l'état aurait convergé sans le hard refresh. Voir 3.9 et la section 6.
- Le namespace `ci-dind-test` et le pod `dind-test` ont disparu avec la reconstruction (déduit, non vérifié).

#### 3.9 PRA v1.3.2 n°2 (rejeu sans intervention)

- **Rejeu à l'identique, sans aucune intervention ni hard refresh.** Console enregistrée avec `script` : `~/.local/share/gitops-lab/logs/pra-v1.3.2-n2-20261008-193904.log`. Prévol conforme. Jeu Gitea frais : **20261008-193912**.
- **Ordre observé (confirmé) :** registre des nœuds workload, sauvegarde `coredns-kind-gitops-management-20261008-194133.json`, redémarrage de CoreDNS sans `[ROLLBACK]`, `[OK] DNS du management : gitea.local -> Service Traefik`, puis Argo CD.
- Commit du PRA **`8f61caf`**, publié par `gitea-publish.sh` (`d0e6d4d..8f61caf`) ; GitHub à `8f61cafe` après le PRA (mirror, sans intervention, `global=OK`). `whoami` répond HTTP 200 sur dev et prod ; Gitea est Synced/Healthy avec son certificat prêt.
- **Après le PRA (confirmé) :**
  - `--status` : entrée DNS en place, code 0.
  - **ClusterIP de Traefik : `10.96.86.113`**, soit la **troisième valeur différente** (`10.96.180.79`, `10.96.251.119`, puis `10.96.86.113`). `gitea.local` renvoie cette adresse depuis un pod jetable.
  - Conteneur jetable `curl` avec la CA du lab, sans `--add-host` : `http=401 verify=0 ip=10.96.86.113`.
  - Inventaire (`--offline`) : `global=OK`. Dev et prod : 0 ligne `rewrite`. `git status` : seul le cadrage reste non suivi.
- **Relevé chronologique des Applications non saines** (toutes les 30 s, sans hard refresh ; heures de Paris ; fichier `pra-v1.3.2-n2-watch-20261008-194603.log`) :

| Heure | Décompte | Applications non saines |
|---|---|---|
| 19:46:03 | 22 Healthy, 2 Progressing, 1 Degraded | `game-2048-dev` et `game-2048-prod` (Progressing), `traefik` (Degraded) |
| 19:46:33 | 24 Healthy, 1 Degraded | `traefik` |
| 19:47:04 | 24 Healthy, 1 Degraded | `traefik` |
| 19:47:34 | **25 Synced/Healthy** | aucune |

- **Événements Argo CD de l'Application `traefik`** (heures UTC ; Paris = UTC+2) :

| Heure (UTC) | Événement |
|---|---|
| 17:44:19 | Synchronisation automatique lancée vers la version `37.1.0` du chart |
| 17:44:20 | `OutOfSync` ; santé `Missing` |
| 17:44:30 | Santé `Missing` -> `Progressing` ; synchronisation terminée |
| 17:44:32 et 17:44:39 | Deux synchronisations partielles automatiques, terminées avec succès |
| 17:44:49 | `OutOfSync` -> `Synced` ; santé `Progressing` -> **`Degraded`** |
| 17:47:09 | Santé `Degraded` -> **`Healthy`** |

  Les deux sources concordent : l'événement `Healthy` (19:47:09, heure de Paris) tombe entre les relevés de 19:47:04 et de 19:47:34. **`Degraded` a duré 2 min 20 s**, et 2 min 50 s se sont écoulées entre le début de la synchronisation et `Healthy`.

### 4. Règles de décision

| Situation | Comportement |
|---|---|
| `check-external-deps.sh` : code 0 | Prévol : `[OK]`, on continue |
| Code 2 (avertissement, par exemple une entrée du hosts Windows absente) | Prévol : `[WARN]`, on continue |
| Code 3 (critique) ou 1 (manifeste invalide) | Prévol : `[STOP]` avant le menu PRA, donc avant toute destruction |
| `configure-management-dns.sh --render-check` en échec ou script absent | Prévol : `[STOP]` avant le menu |
| `configure-management-dns.sh --apply` en échec pendant la reconstruction | `[WARN]` ; le PRA continue ; rejouer le script seul |
| Corefile du management non reconnu | `[STOP]` du script, rien n'est modifié |
| CoreDNS ne redémarre pas après le patch | Retour arrière automatique du Corefile (`[ROLLBACK]`) |

### 5. État de validation v1.3.2 (bilan)

| Élément | Statut |
|---|---|
| CoreDNS identique et sans personnalisation sur les 3 clusters ; ConfigMap écrite par kubeadm seul | **confirmé** |
| TLS vers le registre depuis un conteneur imbriqué, routes nœud et Service Traefik | **confirmé** (401, `verify=0`) |
| `gitea.local` -> Service Traefik depuis un pod et un conteneur imbriqué, sans `--add-host` | **confirmé** (cluster avant PRA, puis clusters reconstruits aux deux PRA) |
| Entrée DNS rejouée par le bootstrap au PRA, avant Argo CD | **confirmé** (PRA n°1 et n°2) |
| La ClusterIP change entre deux PRA, l'entrée reste valide | **confirmé** (`10.96.180.79` -> `10.96.251.119` -> `10.96.86.113`) |
| Retour arrière automatique si CoreDNS ne redémarre pas | **testé contre un faux `kubectl` seulement** |
| Retour arrière manuel (`--rollback`) sur le vrai cluster | **à valider** |
| Dev et prod non modifiés | **confirmé** (après le PRA n°2 aussi) |
| Inventaire : 26 entrées, `--check` à OK, intégré au prévol | **confirmé** |
| Prévol : avertissement ne bloque pas ; manifeste invalide bloque | **confirmé** (tests A et B) |
| Gitea et GitHub à jour après chaque PRA, sans intervention | **confirmé** (`d0e6d4d8`, puis `8f61cafe`) |
| 25 Applications Synced/Healthy après le PRA sans intervention | **confirmé** au PRA n°2 (2 min 50 s après le début de la synchronisation de Traefik) ; au PRA n°1, hard refresh manuel de Traefik, nécessité non établie |
| Traefik `Degraded` transitoire (2 min 20 s) alors que son pod est prêt | **confirmé** (événements et relevés) ; non bloquant : levé seul au PRA n°2 |
| Cause de ce `Degraded` transitoire | **hypothèse** (section 6) |
| Rôle du `rewrite` dans ce `Degraded` | **non établi** ; aucun chemin causal identifié (déduit) ; seul un PRA sans l'entrée DNS le trancherait |
| Confiance du démon Docker dans la CA du lab | **à valider** |
| Push d'image, runner, jeton de publication du registre | **à valider** (v1.3.3) |

### 6. Traefik `Degraded` transitoire après le PRA (constat non expliqué)

**Ce qui est établi :**
- **PRA n°1 :** Traefik était `Degraded` au premier décompte (22 / 2 / 1) et a été rafraîchi à la main. Les noms des deux autres Applications n'ont pas été relevés.
- **PRA n°2 :** sans intervention, `Degraded` du **17:44:49Z au 17:47:09Z** (2 min 20 s), puis `Healthy` seul. Les Applications `game-2048-dev` et `game-2048-prod`, `Progressing` au premier relevé, étaient `Healthy` 30 s plus tard.
- **Le pod de Traefik** a été créé vers 17:44:29Z (âge de 94 s au premier relevé, déduit) et était `1/1 Running`, sans redémarrage, dès le premier relevé. **Aucun événement `Warning`** n'existait dans le namespace `traefik`.
- **Aucune ressource non saine n'a été listée** par le relevé pendant les trois relevés où l'Application était `Degraded`. **Réserve :** la requête ne liste que les ressources portant un état de santé et n'affiche rien si `status.resources` est vide ; ce n'est donc pas la preuve que toutes les ressources étaient saines.
- **Deux synchronisations partielles** automatiques ont eu lieu à 17:44:32 et 17:44:39. Elles ne sont pas interprétées.
- **Journaux du contrôleur Argo CD :** le filtre sur les changements de santé n'a rien renvoyé (le libellé exact n'a pas été confirmé). Les événements Argo CD ont suffi à dater les changements.

**Hypothèse non prouvée :** l'état de santé de l'**Application** est évalué plus lentement que celui de ses ressources, et reste `Degraded` après que le pod est prêt. Éléments en faveur : `Degraded` alors que le pod est prêt et qu'aucune ressource non saine n'est listée ; levé seul en 2 min 20 s ; levé par un hard refresh au PRA n°1. **Limite :** `Degraded` est apparu 30 s après le début de la synchronisation et environ 20 s après la création du pod, ce qui est court pour une cause liée à un démarrage lent (déduit).

**Lien avec le DNS :** aucun chemin causal identifié. L'entrée est posée avant l'installation d'Argo CD et ne concerne que `gitea.local`. Mais ce n'est **pas exclu**. Je ne sais pas si les PRA antérieurs à la v1.3.2 montraient le même `Degraded` : seuls leurs décomptes finaux ont été rapportés. Seul un PRA **sans** l'entrée DNS trancherait ; il n'est pas planifié (coût d'un PRA pour un état transitoire sans conséquence).

**À faire au prochain PRA :** rejouer le relevé chronologique de la section 3.9 ; à la première apparition de `traefik` en `Degraded`, capturer (lecture seule) `kubectl --context kind-gitops-management -n argocd get application traefik -o yaml`, la liste des ressources de l'Application et `kubectl -n argocd get events --field-selector involvedObject.name=traefik`. L'état n'est pas bloquant : le PRA converge seul en environ 3 minutes.

### 7. Points de vigilance et savoir-faire

**DNS et CoreDNS**
- Le Corefile par défaut de Kind est recréé avec le cluster : l'entrée est perdue à toute reconstruction. Après une reconstruction manuelle, hors bootstrap : `bash scripts/configure-management-dns.sh --apply`. Pour un retour arrière : `--rollback`.
- Un redémarrage de pods ou de Docker conserve la ConfigMap ; seule la recréation du cluster la perd.
- Le nom `gitea.local` ne se résout dans un pod qu'**après le déploiement de Traefik** par la Root App. Avant, le bootstrap publie par port-forward et n'en a pas besoin. Juste après un PRA, attendre une ou deux minutes avant de conclure à un échec.
- Un dry-run serveur ne valide pas la syntaxe d'un Corefile : seul le démarrage de CoreDNS la valide.
- `rewrite` sur un nom de Service plutôt qu'une IP : la ClusterIP change à chaque reconstruction (trois valeurs différentes constatées).
- Tout pod du management qui résolvait `gitea.local` en `127.0.0.1` obtient désormais Traefik. Aucun cas connu (Argo CD lit Gitea par son URL interne).

**Inventaire et prévol**
- Un contrôle `covered` vérifie que le texte de la garde existe encore dans `scripts/*.sh` : renommer un message de garde déclenche un `[WARN]` d'inventaire.
- Ajouter un élément hors Git = ajouter une ligne au manifeste dans le même commit.
- Les messages de garde du bootstrap sont un contrat avec le manifeste.
- Une garde de prévol qui s'arrête avant la destruction vaut mieux qu'une garde qui s'arrête après (leçon v1.2.3, reprise ici).

**Procédure**
- Vérifier ce qui est réellement utilisé avant de supprimer : le manifeste `pra-isolated` semblait obsolète et est lu par le bootstrap. Un `grep` ne trouve pas les chemins construits par variable.
- Les `.before-*` sont inutiles dans Git : le retour arrière est `git checkout -- <fichier>`. Pour les fichiers hors Git, une sauvegarde reste justifiée.
- `git push gitea main` a demandé le mot de passe administrateur une fois (cause non établie). `scripts/gitea-publish.sh --push <sha>` utilise le jeton `git-push-wsl` et vérifie l'avance rapide ; c'est le chemin à privilégier.
- Juste après une publication, `git ls-remote origin main` peut renvoyer l'ancien commit pendant quelques secondes (délai du mirror). Confirmer avec `check-github-mirror.sh --check`.
- Une commande qui lit une valeur sensible (CA, jeton) doit afficher seulement des empreintes, des modes ou des noms de clés.
- **Fuseaux :** les événements Kubernetes et Argo CD sont en UTC, les journaux du lab et les relevés en heure de Paris (UTC+2 le 8 octobre 2026). Convertir avant de rapprocher deux sources.
- **Un état d'Application Argo CD relevé trop tôt n'est pas un échec de PRA :** pour la v1.3.2, le décompte est stable environ 3 minutes après le début de la synchronisation de Traefik. Relever dans le temps plutôt qu'une seule fois, et **avant** tout hard refresh, qui efface la trace.
- Les événements Kubernetes sont conservés environ une heure par défaut : les lire tout de suite après un PRA.
- Enregistrer la console d'un PRA : `script -q -f <fichier> -c ./scripts/bootstrap-platform.sh` (garde un vrai terminal, donc le menu reste interactif ; `umask 077` pour un fichier en 600).

**Vérification après PRA (lecture seule)**
```
./scripts/configure-management-dns.sh --status
kubectl --context kind-gitops-management -n traefik get svc traefik -o jsonpath='{.spec.clusterIP}'
kubectl --context kind-gitops-management run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup gitea.local 10.96.0.10
kubectl --context kind-gitops-management -n argocd get applications --no-headers | awk '{print $2"/"$3}' | sort | uniq -c
```

### 8. Feuille de route et points ouverts

**Numérotation proposée (non confirmée, point 6.4 du cadrage)**
```
v1.3.0  fait    Gitea source de vérité
v1.3.1  fait    Dépôt de secours GitHub, rotation du PAT, contrôles PRA
v1.3.2  fait    DNS du management (variante A, rewrite vers le Service Traefik), inventaire hors source de vérité
v1.3.3  prévu   Gitea Actions : runner, workflow minimal jusqu'à dev
v1.4.0  prévu   DNS central du lab, PKI, abandon progressif du hosts Windows, zone définitive
```

**Étape suivante : v1.3.3 — CI Gitea Actions**, avec ce qui reste à faire (section 2.4 du cadrage) :
- **Confiance du démon Docker dans la CA du lab** (certificat dans `/etc/docker/certs.d/gitea.local/`, hypothèse), à valider ;
- jeton de publication du registre, distinct de `git-push-wsl`, et jeton d'enregistrement du runner : à ajouter à l'inventaire ;
- push d'une image au registre, enregistrement d'un runner (nombre de runners déjà enregistrés : **non relevé**), build réel de 2048 (MTU avec de grosses couches), consommation de la limite inotify (512) ;
- runner géré par Argo CD dans le management, épinglé par digest (le test DinD utilisait un pod privilégié non épinglé).

**Points ouverts**
- **Traefik `Degraded` transitoire après le PRA :** cause non établie, non bloquant ; capture à faire au prochain PRA (section 6).
- **Deuxième nettoyage (hors manifeste) :** fichiers à trancher : `workload-dev-cluster-secret.yaml` (Secret Argo CD en clair du 19 septembre, ignoré par Git, référencé par aucun script), `argocd-admin-auth.json` et `argocd-admin-before-change.*`, `gitops-lab-ca-issuer.yaml`, `sealed-secrets-key.yaml` (clé `7sctf`, non active), `network-backups/dev-before-ip-migration`, `gitops-lab-root-ca-test-dl.tar.age` (même taille que l'archive de la CA, doublon probable), anciens formats de sauvegarde Gitea (`gitea-data-*.tar.gz`, `gitea-admin-secret-*.json`).
- **Clé Sealed Secrets :** je n'ai pas vérifié si le contrôleur en génère une nouvelle périodiquement ; si oui, la sauvegarde du bootstrap pourrait devenir obsolète.
- **Rétention des jeux de sauvegarde Gitea :** les jeux antérieurs à `20261007-220927` ne permettent plus de restaurer l'état actuel ; tous contiennent la configuration du mirror, donc des PAT (certains supprimés depuis). Politique à décider.
- **Dossier `dns-backups/` :** non contrôlé par l'inventaire (mode 700, espace). Il grossit d'une sauvegarde par PRA.
- **Manifeste Argo CD dans `pra-isolated` :** le nom du dossier est un héritage ; à revoir en v1.4.0 avec les chemins.
- **Dev et prod et `gitea.local` :** le point 6.3 du cadrage reste ouvert. Aucune entrée n'y est posée tant qu'aucun pod de ces clusters n'en a besoin.
- **`--plan` du bootstrap :** il n'affiche ni le contrôle de l'inventaire ni le DNS (cosmétique).
- **CA dans le magasin WSL :** le fichier `/usr/local/share/ca-certificates/gitops-lab-root-ca.crt` est en 600 root (mode habituel : 644). Seul un outil qui lirait le lien par hash pourrait échouer (hypothèse) ; aucun cas observé.
- **Archive `.tar.age` de la CA :** aucune identité `age` n'est dans le dossier de configuration. Où sont conservées la passphrase ou l'identité ? À documenter (sans la stocker ici).
- **Outils locaux obsolètes :** les scripts de patch de `~/lab/tools` ne peuvent plus s'appliquer (empreintes attendues périmées).
- **Hérités de la v1.3.1 :** profil exploit validé en simulation seulement, abandon par saisie vide non testé, mode sinistre du prévol non conçu, README-bootstrap et `docs/bootstrap-gitops-autonome.md` à mettre à jour, contexte kubectl laissé sur `kind-gitops-prod`, image de base nginx de 2048 non vérifiée comme épinglée.

### 9. Dépendances et risques

- **L'entrée DNS dépend du Service Traefik** (`traefik/traefik`) : si le chart Traefik change le nom ou le namespace du Service, `gitea.local` n'est plus résolu dans les pods. L'inventaire ne le contrôle pas (à envisager).
- **Le hosts Windows reste une dépendance implicite du poste** : le prévol l'indique (`[WARN]`) mais ne la corrige pas. Il ne doit pas être supprimé tant qu'un DNS global n'existe pas.
- **Le suffixe `.local`** reste un risque modéré : mDNS sous Windows et sur les clients Linux avec résolveur multicast. Aucun problème observé.
- **Un échec d'`--apply` pendant la reconstruction n'arrête pas le PRA** : l'entrée peut manquer sans que le PRA échoue. Visible seulement dans le journal et par `--status`.
- **Un contrôle d'état trop précoce après un PRA peut voir un faux `Degraded`** : Traefik reste `Degraded` environ 2 min 20 s dans l'Application, alors que le pod est prêt (section 6). Tout contrôle automatisé de fin de PRA (par exemple avant de lancer la CI) devra attendre ou tester le service lui-même plutôt que l'état d'Argo CD.
- **Les jeux de sauvegarde Gitea contiennent le PAT GitHub** (inchangé depuis la v1.3.1). Prochaine échéance du PAT : 6 janvier 2027.
- **Dépendances externes du PRA, inchangées :** GitHub et les dépôts de charts (jetstack, traefik, metallb, ingress-nginx, metrics-server, sealed-secrets, dl.gitea.io), désormais contrôlés en joignabilité par le prévol.
- **Gitea reste sur le chemin de démarrage de la plateforme** (v1.3.0), avec un dépôt de secours à jour (v1.3.1).
- **Limite inotify :** toujours 512 ; ne pas créer de cluster Kind supplémentaire hors PRA.

### 10. Critères de clôture de v1.3.2

**Version clôturée**, sous réserve du dernier contrôle de publication :
- le cadrage v1.3.2, resté non suivi jusque-là, est validé dans un commit distinct (`8fb97a1`) ; un premier commit (`43bfd9b`) a publié par erreur une version antérieure de ce document (sans le PRA n°2) ; **un second commit, seul dans son contenu, remplace ce fichier par la version finale** ; publication dans Gitea par `gitea-publish.sh`, sans push forcé : l'historique publié n'est pas réécrit ;
- après une trentaine de secondes, `./scripts/check-github-mirror.sh --check` à `global=OK`, code 0 ;
- tag annoté v1.3.2 sur le commit qui apporte la version finale de ce document, poussé vers Gitea, puis **recopié sur GitHub par le mirror**, à vérifier par un nouveau `--check` ;
- release v1.3.2 créée dans Gitea, case de réécriture du message du tag **décochée** (règle « tag publié = figé ») ; elle n'existera pas sur GitHub, comme prévu.

**Point de reprise :** v1.3.3, CI Gitea Actions, en commençant par la confiance du démon Docker dans la CA du lab, puis le jeton de publication du registre.

### Sources de référence

- Capitalisations v1.2.0 à v1.3.1 et cadrage v1.3.2.
- Preuves v1.3.2 : sorties de commandes du 8 octobre 2026 (relevés CoreDNS, tests TLS et DNS, prévol, deux PRA, événements Argo CD de Traefik, journaux dans `~/.local/share/gitops-lab/logs/`), sauvegardes `~/.local/share/gitops-lab/dns-baseline-20261008-185030` et `dns-backups/`.
- Documentation consultée : RFC 6762 (multicast DNS, domaine `.local`) ; ICANN, réservation de `.internal` (source secondaire : ICANNWiki) ; CoreDNS, plugins `rewrite` et `hosts` ; Kubernetes, personnalisation du service DNS ; WSL, DNS tunneling (2.2.1 et plus). Elle décrit les outils mais ne prouve pas l'état du lab.
