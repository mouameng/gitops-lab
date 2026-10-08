# GitOps Lab — Capitalisation v1.3.1 : dépôt de secours GitHub par push mirror, contrôle et rotation du PAT intégrés au PRA

**Statut : v1.3.1 clôturée le 8 octobre 2026.** Gitea reste la source de vérité GitOps (v1.3.0). Il pousse désormais automatiquement chaque commit, branche et tag vers GitHub (`mouameng/gitops-lab`), qui devient un **dépôt de secours tenu à jour** et n'est plus une copie figée. Un nouveau script, `scripts/check-github-mirror.sh`, contrôle ce dépôt de secours (échéance du PAT GitHub, état du mirror, égalité des références). Il sait aussi remplacer le PAT sans interruption du mirror. Le bootstrap l'appelle en prévol (contrôle seul) et, pendant le PRA, avant la sauvegarde fraîche de Gitea (remédiation selon un profil `lab` ou `exploit`). Le PRA multicluster a été rejoué **deux fois** : une fois sur le chemin nominal, une fois avec une rotation déclenchée par le bootstrap.

**Révision de référence :** le tag `v1.3.1` désigne la révision qui **ajoute ce document** dans Gitea. Son parent est le commit `96ff9b4` (`chore(pra): renew workload registrations`, PRA n°2). Le hash du commit de clôture n'est pas inscrit ici : utiliser `git rev-parse 'v1.3.1^{commit}'`.

**Remplace :** `gitops-lab-capitalisation-v1.3.0-cloturee-2026-10-07.md`. Le contenu de la v1.3.0 (Gitea source de vérité, installation directe au PRA, publication par port-forward) reste acquis ; seul un rappel bref figure en section 3. Les versions plus anciennes restent dans `docs/`.

**Changement de feuille de route :** la CI Gitea Actions, initialement prévue en v1.3.1, est décalée en **v1.3.2**. Le dépôt de secours a été priorisé pour sécuriser une copie exploitable avant d'ajouter de nouveaux composants.

**Périmètre :** push mirror Gitea → GitHub, autorisation réseau de Gitea, script de contrôle et de rotation, intégration au bootstrap, deux PRA, test d'échéance réelle avec un PAT de 7 jours.

**Convention de lecture :**
- **confirmé** : sortie ou capture rapportée dans les échanges ;
- **hypothèse** : explication cohérente avec les observations, non prouvée ;
- **à valider** : pas encore démontré.

Une commande citée sans résultat ne vaut pas preuve de son exécution.

---

## 1. Synthèse

À la clôture de la v1.3.0, GitHub était volontairement figé sur `v1.2.3` (`7e8f856`). En cas de perte de Gitea, le dépôt de secours aurait donc été en retard sur toute la v1.3.0. L'objectif de la v1.3.1 était de **tenir GitHub à jour automatiquement**, et de **ne pas laisser cette copie se dégrader silencieusement**, notamment à l'échéance du jeton GitHub.

**Décisions :**
- **Push mirror natif de Gitea**, synchronisé à chaque commit et toutes les heures, avec un **PAT GitHub fine-grained** limité au seul dépôt `gitops-lab` et à la permission *Contents: Read and write*, valable 90 jours.
- **Le renouvellement du PAT n'est pas entièrement automatisable** : un PAT GitHub se crée dans l'interface. Une GitHub App, plus adaptée aux intégrations longues, n'a pas été retenue pour un lab (complexité). L'automatisation porte donc sur la **détection** de l'échéance et sur la **remise en état du mirror**, pas sur la création du jeton.
- **Séparation des responsabilités :**
  - `check-github-mirror.sh --check` constate, sans écriture ni question ;
  - `--update` remédie ;
  - le bootstrap **décide** selon un profil.
- **Deux profils :**
  - `lab` (défaut) : remédiation lancée d'office, arrêt du PRA seulement si elle échoue ;
  - `exploit` : confirmation explicite, avec un refus bloquant en état critique.
- **Remédiation avant la sauvegarde fraîche de Gitea** : la configuration du mirror est sauvegardée et restaurée avec les données de Gitea. Une rotation faite après la sauvegarde serait perdue au PRA.
- **Autorisation ciblée de `github.com`** dans la configuration de Gitea (`migrations.ALLOWED_DOMAINS`), plutôt qu'une ouverture des réseaux locaux.

**État au 8 octobre 2026 :**
- Mirror `remote_mirror_u0MpejyusM` actif, sans erreur. GitHub et Gitea ont les mêmes branches et tags (15 références).
- Un seul PAT GitHub, `gitea-mirror-gitops-lab-2026-10-final`, échéance **6 janvier 2027**.
- `scripts/check-github-mirror.sh` versionné (modes `--check` et `--update`).
- `scripts/bootstrap-platform.sh` patché (+73 lignes, aucune suppression).
- **PRA rejoué deux fois** : 25 Applications `Synced/Healthy` et mirror restauré et fonctionnel à chaque fois. Le commit du PRA a été recopié sur GitHub sans intervention.
- **Reporté (section 8) :** profil `exploit` validé seulement en simulation, test d'abandon de saisie, mode sinistre du prévol, CI (v1.3.2).

---

## 2. Architecture de référence

### 2.1 Chaîne Git

```text
Poste WSL --- git push / gitea-publish.sh ---> Gitea (source de vérité, cluster management)
                                                   |
                                                   | push mirror (à chaque commit + toutes les 1h)
                                                   | PAT GitHub fine-grained, dépôt gitops-lab seul
                                                   v
                                               GitHub mouameng/gitops-lab (dépôt de secours)

Argo CD --- lit ---> Gitea (URL interne, inchangé depuis la v1.3.0)
```

**Ce qui est recopié :** commits, branches et tags.
**Ce qui ne l'est pas :** les **releases** Gitea (titre, description), qui sont des objets de la base de la forge et non des objets Git. Ce point a été établi en v1.3.0 ; il est accepté.

**Point d'attention :** le push mirror effectue des **push forcés**. Toute modification faite directement sur GitHub serait écrasée à la synchronisation suivante. GitHub ne doit donc jamais être modifié directement.

### 2.2 Paramètres du mirror (confirmés)

| Paramètre | Valeur |
|---|---|
| URL distante | `https://github.com/mouameng/gitops-lab.git` |
| Utilisateur | `mouameng` |
| Mot de passe | PAT GitHub fine-grained (jamais versionné) |
| Synchroniser à chaque commit | Oui |
| Intervalle | `1h0m0s` |
| Configuration Gitea requise | `[migrations] ALLOWED_DOMAINS = github.com` |

### 2.3 Fichiers locaux (hors dépôt)

| Fichier | Contenu | Mode |
|---|---|---|
| `~/.config/gitops-lab/gitea-git-token` | Jeton Gitea `git-push-wsl` (inchangé), utilisé aussi pour l'API Gitea | 600 |
| `~/.config/gitops-lab/github-mirror-token.env` | `GITHUB_MIRROR_TOKEN_EXPIRES=AAAA-MM-JJ` uniquement, **sans le PAT** | 600 |
| `~/lab/tools/patch-bootstrap-mirror.py` | Outil de patch du bootstrap (non suivi) | 755 |

Le PAT GitHub lui-même n'est stocké **que dans Gitea** (configuration du mirror) et dans ton gestionnaire de mots de passe.

### 2.4 Ordre du bootstrap (ajouts v1.3.1)

```text
Prévol (aussi exécuté par --preflight)
  ... gardes v1.3.0 (main local = gitea/main, gitea-publish.sh --check, install-gitea-direct.sh --render-check)
  [NOUVEAU] Validation de MIRROR_PROFILE (lab | exploit), présence du script
  [NOUVEAU] check-github-mirror.sh --check : affichage seul, jamais d'arrêt ni de question
  ... gardes Git, Argo CD, CA (inchangées)
  --preflight s'arrête ici

PRA
  Menu de confirmation (1 = refuser, 2 = détruire)
  [NOUVEAU] Remédiation du dépôt de secours selon le profil (voir 5.2)
  Sauvegarde fraîche de Gitea, jeu figé          <- inclut la configuration du mirror
  Destruction puis reconstruction (inchangées)
  Publication du commit de PRA vers Gitea        <- recopié vers GitHub par le mirror
```

---

## 3. Rappel v1.3.0 (acquis, non repris en détail)

Gitea héberge `gitea_admin/gitops-lab` (SHA-1). Argo CD le lit par l'URL interne du service. Au PRA, Gitea est restauré puis installé directement (`install-gitea-direct.sh`) avant toute dépendance au dépôt. Le commit de renouvellement des enregistrements est publié par `gitea-publish.sh` via port-forward. Voir `gitops-lab-capitalisation-v1.3.0-cloturee-2026-10-07.md`.

---

## 4. Travaux réalisés et preuves

### 4.1 État initial et continuité de l'historique (confirmé)

- `git ls-remote` sur les deux serveurs :
  - **Gitea** : `main` = `190f2fd` (`v1.3.0`) ;
  - **GitHub** : `main` = `7e8f856` (`v1.2.3`) ;
  - **tags** : les 7 tags historiques sont identiques, empreintes des tags annotés comprises. `v1.3.0` n'existait que sur Gitea.
- **Correction du document v1.3.0 :** **aucune branche `pra/*`** n'existait sur l'un ou l'autre serveur. Le point ouvert « pousser les branches `pra/*` avant le mirror » était donc sans objet.
- `git merge-base --is-ancestor 7e8f856 190f2fd` → code `0` : le `main` de GitHub était un ancêtre de celui de Gitea. Le premier push forcé du mirror ne pouvait donc qu'**avancer** GitHub, sans perte.

### 4.2 Création du PAT GitHub

- Parcours : **avatar → Settings → Developer settings → Personal access tokens → Fine-grained tokens**.
- **Piège rencontré :** le menu *Settings* du **dépôt** (où figure *Deploy keys*) n'est pas celui du **compte**. Les PAT se gèrent depuis les paramètres du compte.
- Paramètres retenus : dépôt `gitops-lab` seul, *Contents: Read and write*, aucune autre permission, expiration 90 jours.
- **Observation non expliquée :** GitHub affiche « Never used » sur des PAT qui ont pourtant servi (des commits sont arrivés sur GitHub pendant qu'ils étaient le seul jeton du mirror). On ne peut pas se fier à cette mention pour savoir quel jeton est utilisé. La cause n'est pas établie.

### 4.3 Refus d'ajout du mirror et diagnostic

**Symptôme (confirmé) :** à l'ajout du mirror, Gitea refuse l'URL GitHub avec un message de contrôle des domaines citant `ALLOWED_DOMAINS`, `ALLOW_LOCALNETWORKS` et `BLOCKED_DOMAINS`. Aucun mirror n'est créé.

**Investigation (toutes en lecture seule) :**

| Contrôle | Résultat |
|---|---|
| `infrastructure/gitea/values.yaml` | Aucun des trois paramètres déclaré |
| Versions | Chart `12.7.0`, Gitea **`1.27.0`** |
| Fichier de configuration effectif | `/data/gitea/conf/app.ini` |
| Recherche dans **tout** le fichier | Aucune clé de restriction déclarée |
| Résolution DNS depuis le pod | `140.82.121.4` **et** `64:ff9b::8c52:7904` |
| Journaux Gitea au moment du refus | Aucune ligne pertinente |
| `git ls-remote` vers GitHub depuis le pod | Fonctionne (`7e8f856 refs/heads/main`) |

**Analyse :**
- **Confirmé :** le réseau, le DNS et le TLS vers GitHub fonctionnent depuis le pod Gitea. Le refus vient donc du filtre de Gitea, pas de la connectivité.
- **Confirmé :** l'adresse IPv6 renvoyée appartient au préfixe de traduction IPv4/IPv6 `64:ff9b::/96` (RFC 6052, NAT64). Ce n'est pas une adresse publique classique.
- **Hypothèse non prouvée :** Gitea a considéré cette adresse comme non publique, et l'a refusée au titre de `ALLOW_LOCALNETWORKS = false` (valeur par défaut).

**Correction retenue :** déclarer `github.com` dans `ALLOWED_DOMAINS`. Selon la documentation de la branche 1.27, un domaine explicitement autorisé n'est pas soumis au contrôle des réseaux locaux. Cette correction est ciblée : elle n'ouvre pas les réseaux locaux et ne désactive pas le TLS.

```yaml
gitea:
  config:
    migrations:
      ALLOWED_DOMAINS: "github.com"
```

- Contrôle avant commit : `git diff --check` et `install-gitea-direct.sh --render-check` conformes (7 objets).
- Commit **`757f738`** (`fix(gitea): allow github.com for push mirror`), poussé vers Gitea.

**Prise en compte par Argo CD — piège rencontré (confirmé) :**
- Après le push, l'Application `gitea` restait `Synced / Healthy`… mais sur l'**ancienne** révision `190f2fd`. `ALLOWED_DOMAINS` était absent du pod.
- Un **hard refresh** (`argocd.argoproj.io/refresh=hard`) a fait apparaître la révision `757f738` et l'état `OutOfSync`.
- Après une synchronisation manuelle (sans *Force* ni *Prune*) : `Synced / Healthy`, opération `Succeeded`, et `ALLOWED_DOMAINS = github.com` présent dans `app.ini`.
- L'ajout du mirror a ensuite été accepté.

**Conséquence durable :** la liste `ALLOWED_DOMAINS` restreint les migrations et mirrors de Gitea aux seuls domaines listés. Toute future migration depuis un autre domaine devra l'y ajouter.

**Erreur de démarche à retenir :** une étape du diagnostic s'est appuyée sur la documentation d'une version de Gitea **plus récente** que celle installée (clés `EGRESS_MODE`, `ALLOWED_HOST_LIST`). Elle a été corrigée en consultant la documentation de la branche 1.27. Voir section 7.

### 4.4 Première synchronisation (confirmé)

- Mirror enregistré : *Soumission (1h0m0s)*, « Dernière mise à jour : Jamais ». **L'enregistrement seul ne prouvait pas la synchronisation.**
- Après **Synchroniser maintenant** : dernière mise à jour le 8 octobre 2026 à 10:18:36.
- `git ls-remote` des deux côtés : branches et tags **identiques**. `main` = `757f738`, `v1.3.0` conserve son empreinte.

### 4.5 API Gitea disponible (confirmé, instance 1.27.0)

- Le jeton existant `git-push-wsl` permet de **lire** les push mirrors (`GET /repos/{owner}/{repo}/push_mirrors`).
- Le schéma `swagger.v1.json` de l'instance expose : `GET` (liste et détail), `POST` (création), `DELETE`, `POST …/push_mirrors-sync`.
- **Aucun `PUT` ni `PATCH`** : on ne peut pas modifier le jeton d'un mirror existant par l'API.
- Champs de création (`CreatePushMirrorOption`) : `remote_address`, `remote_username`, `remote_password`, `interval`, `sync_on_commit`.

**Conséquence sur la conception :** la rotation se fait en **créant un second mirror, puis en supprimant l'ancien**, pour éviter toute période sans mirror.

### 4.6 Script `check-github-mirror.sh` — mode `--check` (v1)

- Contrôles :
  1. **Échéance du PAT**, lue dans `github-mirror-token.env`. Le jeton est considéré expiré dès 00:00, heure locale, du jour affiché par GitHub (convention prudente).
  2. **État du mirror**, par l'API Gitea : présence, absence d'erreur, synchronisation déjà effectuée, `sync_on_commit`. Le texte brut des erreurs n'est jamais affiché.
  3. **Égalité des branches et tags**, par lecture anonyme des deux dépôts. Les écarts sont listés.
- Codes retour : **`0`** OK, **`2`** avertissement, **`3`** critique, **`1`** erreur d'usage.
- Seuils par défaut : **14 jours** (avertissement), **24 heures** (critique). Ils sont réglables par `MIRROR_WARN_DAYS` et `MIRROR_CRIT_HOURS`.
- Le jeton Gitea est envoyé à `curl` en en-tête par l'entrée standard, jamais en argument.

**Preuves :**
- empreinte vérifiée à l'installation (`959ca255…`) ;
- premier contrôle réel : `global=OK`, code `0` ;
- dates simulées par fichier temporaire (le vrai fichier n'est pas modifié) : J+7 → `WARN`, code `2` ; J0 → `CRIT`, code `3` ;
- commit **`cd7b6b9`** poussé vers Gitea puis, **moins de 30 s plus tard**, présent sur GitHub sans clic : **la synchronisation à chaque commit est confirmée**.

### 4.7 Mode `--update` (v2) et première rotation

**Comportement :**

| Résultat de `--check` | Action de `--update` |
|---|---|
| OK | Rien |
| PAT en avertissement ou critique, ou mirror critique | Rotation |
| Seules les références diffèrent | Arrêt : inspection manuelle, **pas de push forcé automatique** |
| Autre avertissement | Rien |

**Déroulé de la rotation :**
1. saisie masquée du nouveau PAT (format `github_pat_…` vérifié) et de sa date d'expiration (refusée si à moins de 24 h) ;
2. création d'un second mirror avec les mêmes paramètres ;
3. synchronisation, puis attente du succès (jusqu'à 180 s) ;
4. comparaison des branches et tags ;
5. suppression de l'ancien mirror ;
6. enregistrement de la nouvelle date, puis nouveau `--check`.

**En cas d'échec :** seul le nouveau mirror est supprimé ; l'ancien reste en place. Sans terminal interactif : arrêt avec le code `3`.

**Gestion du PAT :** jamais en argument ni affiché. Il n'est écrit que dans un fichier temporaire en mode `600`, supprimé dès la création du mirror.

**Preuves (confirmées) :**
- empreinte `e431497f…` vérifiée à l'installation ;
- rotation forcée par `MIRROR_WARN_DAYS=120` : `remote_mirror_OinOhmuQ3D` → `remote_mirror_atCtjLZfTP`, synchronisation `ok` en 10 s, références identiques ;
- **inconnues levées :** Gitea accepte temporairement **deux mirrors vers la même URL**, et la synchronisation globale déclenche bien le nouveau mirror ;
- ancien PAT supprimé dans GitHub, puis commit **`c79e53a`** poussé : `--check` à `OK`. **Le nouveau PAT suffit seul.**

**Non testé :** l'abandon par saisie vide (le test prévu n'a pas été exécuté). Voir section 8.

### 4.8 Intégration au bootstrap

- Outil `patch-bootstrap-mirror.py` (`ffa65e46…`), sur le modèle des patchs de la v1.3.0 :
  - empreinte du bootstrap exigée : `ca1eb640…` ;
  - chaque ancre doit être trouvée exactement une fois ;
  - refus si le patch est déjà présent ;
  - dry-run par défaut ;
  - sauvegarde `.before-mirror-check` avant écriture.
- **Testé sur une copie factice :** les quatre garde-fous, puis la logique de décision avec un faux script de contrôle (`lab` OK, avertissement, critique avec échec ; erreur du contrôle ; `exploit` avertissement et critique sans réponse ; profil invalide).
- **Application au fichier réel :** 73 lignes ajoutées, aucune supprimée. `bash -n` et `git diff --check` conformes. Nouvelle empreinte : `6e35d3598daca1695504b3824907831b8773dd8f519aff498f98a617343e6c25`.
- Commit **`3a38fc8`** (`feat(pra): check GitHub mirror in preflight and remediate before Gitea backup`).
- **`--preflight` réel :** contrôle exécuté au bon endroit, `[OK] Dépôt de secours GitHub conforme (profil lab)`, code `0`, aucune action Kind ni Kubernetes.

### 4.9 PRA v1.3.1 n°1 (chemin nominal)

- Jeu Gitea **`20261008-110757`**. Contrôle à `OK` au prévol : aucune remédiation lancée, PRA poursuivi normalement.
- Commit **`a523bb8`** (`renew workload registrations`), publié par port-forward pendant le PRA.
- **Après le PRA (confirmé) :**
  - `--check` : `global=OK`. Le commit `a523bb8` est présent sur GitHub **sans intervention** ;
  - 25 Applications `Synced/Healthy` ;
  - un seul mirror, `remote_mirror_atCtjLZfTP`, **le même qu'avant le PRA**. Dernière mise à jour à 11:15:08 (heure de Paris), après la sauvegarde.

**Ce que ce PRA prouve :**
- la configuration du mirror, **identifiants compris**, est sauvegardée puis restaurée avec les données de Gitea ;
- la synchronisation à chaque commit fonctionne dès la réinstallation directe, avant même l'arrivée de Traefik ;
- `ALLOWED_DOMAINS` est bien appliqué au PRA, puisque l'installation directe utilise les mêmes values qu'Argo CD.

### 4.10 PRA v1.3.1 n°2 (rotation déclenchée par le bootstrap)

- Lancement : `MIRROR_WARN_DAYS=120 ./scripts/bootstrap-platform.sh`, profil `lab` par défaut. Nouveau PAT `…-2026-10-pra2` saisi.
- **Ordre observé dans le journal (confirmé) :**
  1. prévol : `[WARN] Dépôt de secours en avertissement … (profil lab)` ;
  2. menu PRA : choix `2` ;
  3. rotation lancée **sans autre question** que le PAT et la date : `remote_mirror_EY2gOuTWiQ` créé, `remote_mirror_atCtjLZfTP` supprimé ;
  4. `[OK] Dépôt de secours GitHub traité avant sauvegarde Gitea` ;
  5. **ensuite seulement**, sauvegarde fraîche : jeu **`20261008-113703`** ;
  6. suite habituelle du PRA, commit **`96ff9b4`**.
- **Après le PRA (confirmé) :** `--check` à `global=OK` ; 25 Applications `Synced/Healthy` ; un seul mirror, **`remote_mirror_EY2gOuTWiQ`** (le nouveau), resynchronisé à 11:42:59 (heure de Paris).
- L'ancien PAT `…-2026-10` a ensuite été supprimé dans GitHub ; le contrôle est resté à `OK`.

**Ce que ce PRA prouve :** la remédiation du profil `lab` se lance d'office, au bon moment, et le mirror recréé par la rotation est bien celui qui est sauvegardé et restauré.

**Remarque :** les avertissements pendant ce PRA venaient de `MIRROR_WARN_DAYS=120`, qui s'applique aussi au contrôle final de la rotation. Ils sont attendus.

### 4.11 Test d'échéance réelle avec un PAT de 7 jours (hors bootstrap)

L'objectif était de valider la détection d'une **vraie** échéance, et pas seulement d'un seuil artificiel.

| Temps | Action | Résultat (confirmé) |
|---|---|---|
| **A** | `--update` avec un PAT `…-test-7j` (échéance 2026-10-15) | `remote_mirror_CjiWSy77K8` remplace `EY2gOuTWiQ`, date enregistrée `2026-10-15` |
| **B** | `--check` **sans aucune variable** | `[WARN] … sous 14 jours (reste 6 j)`, `global=WARN`, code `2` |
| **C** | `--update` **sans aucune variable**, PAT `…-final` de 90 jours | Rotation lancée sur la vraie échéance, `remote_mirror_u0MpejyusM` remplace `CjiWSy77K8`, contrôle final `OK` **sans avertissement**, code `0` |

Après le test, les PAT `…-test-7j` et `…-pra2` ont été supprimés. **Il ne reste que `gitea-mirror-gitops-lab-2026-10-final`.** `--check` est à `OK`.

**Limite :** le temps C a été lancé directement. Lancé par le bootstrap, le même chemin a été validé au PRA n°2, mais avec un avertissement simulé.

**Preuve encore attendue :** les dépôts étant identiques au moment du nettoyage, aucun push n'a encore utilisé le PAT `…-final` seul. Le commit de **ce document** apportera cette preuve (section 10).

---

## 5. Règles de décision

### 5.1 Niveaux du contrôle

| Niveau | Critères | Code |
|---|---|---|
| **OK** | Échéance à plus de 14 jours, un mirror sans erreur déjà synchronisé, références identiques | 0 |
| **Avertissement** | Échéance entre 24 h et 14 jours, ou `sync_on_commit` inactif | 2 |
| **Critique** | Échéance à moins de 24 h ou dépassée ; date absente ou invalide ; aucun mirror ; mirror en erreur ou jamais synchronisé ; API Gitea inaccessible ; références différentes ou illisibles | 3 |

### 5.2 Comportement du bootstrap après confirmation du PRA

| Profil | Avertissement (2) | Critique (3) | Erreur du contrôle |
|---|---|---|---|
| **`lab`** (défaut) | Rotation lancée d'office | Rotation lancée d'office | Arrêt |
| **`exploit`** | Question, délai 60 s, **non** par défaut ; refus ou délai = PRA poursuivi avec avertissement | Question **sans délai** ; refus = **PRA annulé** | Arrêt |

**Après une rotation, dans les deux profils :** nouveau `--check`. Le PRA s'arrête si la rotation a échoué (y compris une saisie vide) ou si l'état reste critique. **Tout arrêt a lieu avant la sauvegarde et avant la destruction : aucun cluster n'est supprimé.**

**`--preflight` :** contrôle seul, aucune question, aucune rotation, quel que soit le profil.

### 5.3 Rotation manuelle (hors PRA)

```bash
cd ~/lab/gitops-lab
./scripts/check-github-mirror.sh --check       # constat
# Créer le nouveau PAT dans GitHub (paramètres de la section 4.2)
./scripts/check-github-mirror.sh --update      # rotation si avertissement ou critique
./scripts/check-github-mirror.sh --check       # doit revenir à OK
# Puis seulement : supprimer l'ancien PAT dans GitHub
```

Pour forcer une rotation alors que le jeton est encore valide : `MIRROR_WARN_DAYS=120 ./scripts/check-github-mirror.sh --update`.

---

## 6. État de validation v1.3.1 (bilan)

| Élément | Statut |
|---|---|
| Mirror Gitea → GitHub configuré et synchronisé | **confirmé** |
| Synchronisation automatique à chaque commit | **confirmé** (`cd7b6b9`, `c79e53a`, `a523bb8`, `96ff9b4`) |
| `ALLOWED_DOMAINS = github.com` appliqué par Argo CD et au PRA | **confirmé** |
| Cause exacte du refus initial (NAT64) | **hypothèse** |
| `--check` : niveaux et codes 0 / 2 / 3 | **confirmé** |
| `--update` : rotation sans coupure, deux mirrors temporaires acceptés | **confirmé** (4 rotations réelles) |
| `--update` : abandon par saisie vide | **à valider** |
| Prévol réel avec contrôle intégré | **confirmé** |
| PRA nominal : mirror restauré et fonctionnel | **confirmé** (PRA n°1) |
| PRA avec rotation `lab` avant la sauvegarde | **confirmé** (PRA n°2, avertissement simulé) |
| Détection d'une échéance réelle, puis renouvellement | **confirmé** (temps B et C, hors bootstrap) |
| Profil `exploit` | **simulation seulement** (copie factice) |
| Le PAT `…-final` pousse seul vers GitHub | **à valider** au commit de ce document |
| Plateforme après chaque PRA | **confirmé** (25 `Synced/Healthy`) |

---

## 7. Points de vigilance et savoir-faire

**Push mirror**
- Le mirror **force** les push : ne jamais modifier GitHub directement. Avant la première activation, vérifier que l'historique distant est un ancêtre de l'historique local (`merge-base --is-ancestor`).
- Enregistrer un mirror ne prouve pas qu'il fonctionne : vérifier la date de dernière mise à jour, puis comparer les références des deux côtés.
- Les releases ne sont pas recopiées ; seuls les objets Git le sont.

**Configuration de Gitea**
- Toujours consulter la documentation de **la version installée** (`gitea --version`). Les clés de configuration évoluent d'une version à l'autre.
- Préférer une autorisation ciblée (`ALLOWED_DOMAINS`) à une ouverture globale (`ALLOW_LOCALNETWORKS = true`).
- Distinguer « le réseau fonctionne » (`git ls-remote` depuis le pod) de « le filtre applicatif autorise ». Les deux se testent séparément.
- Une résolution DNS en `64:ff9b::/96` (NAT64) peut être traitée comme une adresse non publique par un filtre applicatif.

**Argo CD**
- `Synced` signifie « conforme à la dernière révision connue », pas « conforme au dernier commit poussé ». Toujours vérifier la **révision** affichée ; un *hard refresh* force la relecture du dépôt.

**PAT GitHub**
- Un PAT de compte se crée depuis les paramètres du **compte**, pas du dépôt.
- La mention « Never used » de GitHub n'est pas fiable pour identifier le jeton en service : se fier aux commits effectivement recopiés.
- Ne supprimer l'ancien PAT qu'après une rotation validée par `--check`. Ne prouver l'usage du nouveau qu'avec un vrai push.
- La rotation par création puis suppression évite toute période sans mirror. Elle a été choisie parce que l'API 1.27.0 ne permet pas de modifier un mirror.

**Sauvegardes**
- La configuration du mirror, **identifiants compris**, fait partie des données de Gitea. Les jeux de sauvegarde contiennent donc de quoi pousser vers GitHub : leur sensibilité augmente.
- Toute modification de cette configuration doit précéder la sauvegarde fraîche du PRA, sinon elle est perdue à la restauration.

**Tests**
- Simuler un seuil (`MIRROR_WARN_DAYS`) teste la décision ; seule une vraie date proche teste la détection. Les deux ont été faits.
- Une variable de simulation s'applique aussi aux contrôles finaux : un avertissement final est alors attendu.

---

## 8. Feuille de route et points ouverts

**Points ouverts**
- **Profil `exploit` :** validé seulement sur une copie factice. Les questions avec délai et le refus bloquant sont à jouer sur le vrai bootstrap si ce profil doit servir.
- **Abandon par saisie vide :** le refus de rotation par saisie vide n'a pas été exécuté sur le vrai script. Attendu : arrêt, code `3`, mirror inchangé, sans `[ROLLBACK]`.
- **Mode sinistre du prévol :** le prévol suppose toujours un Gitea vivant (`gitea/main`, API Gitea via `gitea.local`). Le dépôt de secours GitHub étant maintenant à jour, un mode de reprise depuis GitHub est **devenu possible**, mais il n'est pas conçu.
- **Prochaine échéance du PAT :** 6 janvier 2027. Le contrôle passera en avertissement autour du 23 décembre 2026 ; le prochain PRA en profil `lab` lancera alors la rotation.
- **Documentation :** `README-bootstrap.md` et `docs/bootstrap-gitops-autonome.md` citent encore GitHub comme dépôt de référence (hérité de la v1.3.0). Ils doivent décrire GitHub comme dépôt de secours.
- **`--plan` du bootstrap :** affiche toujours l'ancien ordre des étapes et n'évoque pas le contrôle du mirror ; cosmétique.
- **Fichiers `.before-*` non suivis :** nombreux dans `scripts/` (dont `.before-mirror-check`) ; un nettoyage ou un rangement est à décider.
- **Contexte `kubectl` :** le bootstrap laisse le contexte courant sur `kind-gitops-prod` à la fin du PRA ; sans impact sur les commandes qui précisent `--context`.
- **Image de base nginx de 2048 :** toujours non vérifiée comme épinglée par digest (hérité).

**Étape suivante : v1.3.2 — CI Gitea Actions.** Inchangé par rapport à la feuille de route v1.3.0 :
- test de faisabilité d'un DinD dans un nœud Kind du management, en premier, avec un pod jetable ;
- séparer ce test de celui des accès depuis les conteneurs de jobs (dépôt, réseau, TLS, registre) ;
- runner géré par Argo CD dans le cluster management ;
- jeton de publication dédié pour le registre, distinct de `git-push-wsl` ;
- objectif : commit → build → push de l'image → digest dans l'overlay **dev** ; promotion vers prod en version séparée.

---

## 9. Dépendances et risques

- **GitHub est maintenant à jour, mais reste écrasé par le mirror :** une modification faite directement sur GitHub serait perdue.
- **Le PAT GitHub expire le 6 janvier 2027.** Sans rotation, le mirror passera en erreur et le dépôt de secours cessera d'avancer. Le contrôle de prévol rend cette dérive visible, **mais seulement quand un prévol ou un PRA est lancé**.
- **Les jeux de sauvegarde Gitea contiennent le PAT GitHub** (via la configuration du mirror). Leur perte ou leur diffusion expose un jeton capable d'écrire dans `gitops-lab`.
- **`ALLOWED_DOMAINS = github.com`** limite toute future migration ou mirror de Gitea à GitHub seul.
- **Dépendances externes du PRA, inchangées :** GitHub (charts Helm de base) et `dl.gitea.io` (chart Gitea).
- **Gitea reste sur le chemin de démarrage de la plateforme** (v1.3.0). La différence avec la v1.3.0 : une copie à jour existe désormais sur GitHub, même si son utilisation en reprise n'est pas automatisée.
- **Limite inotify :** toujours 512 ; éviter de créer un cluster Kind supplémentaire hors PRA.

---

## 10. Critères de clôture de v1.3.1

**Version clôturée**, sous réserve du dernier contrôle de publication :

1. commit de ce document seul dans `docs/`, puis `git push gitea main` ;
2. après une trentaine de secondes, `./scripts/check-github-mirror.sh --check` à `global=OK`, code `0`. **C'est la preuve que le PAT `…-final` pousse seul vers GitHub** ;
3. tag annoté `v1.3.1` sur ce commit, poussé vers Gitea, puis **recopié sur GitHub par le mirror**, à vérifier par un nouveau `--check` ;
4. release `v1.3.1` créée dans Gitea, case de réécriture du message du tag **décochée** (règle « tag publié = figé »). Elle n'existera pas sur GitHub, comme prévu.

**Point de reprise :** v1.3.2, CI Gitea Actions, en commençant par le test de faisabilité DinD dans un nœud Kind du management.

---

## Sources de référence

- Capitalisations v1.2.0 à v1.3.0.
- Preuves v1.3.1 : sorties de commandes, captures de Gitea, de GitHub et d'Argo CD, journaux des deux PRA du 8 octobre 2026 (`~/.local/share/gitops-lab/logs/`).
- Documentation consultée :
  - Gitea : mirroring de dépôt, API des push mirrors, configuration de la branche 1.27 ;
  - GitHub : gestion des PAT fine-grained, expiration et révocation des jetons ;
  - Argo CD : annotations, dont `argocd.argoproj.io/refresh` ;
  - Git : `merge-base`, `ls-remote` ;
  - IETF : RFC 6052 (préfixe `64:ff9b::/96`).

  Elle décrit les outils mais ne prouve pas l'état du lab.
