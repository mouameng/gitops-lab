# GitOps Lab — Note v1.3.3 : reproductibilité des builds, tags et digests (à intégrer au document de la v1.3.3)

**Statut : note de travail du 9 octobre 2026.** Elle garde la trace d'un incident et des décisions prises autour de la CI de `games/2048`, pour les reporter dans le document de la v1.3.3 et décider plus tard si on les reprend. Ce n'est pas une clôture.

**Convention de lecture :**
- **confirmé** : sortie ou capture rapportée dans les échanges ;
- **déduit** : conséquence logique d'éléments confirmés, non testée directement ;
- **hypothèse** : explication plausible, non prouvée ;
- **à valider** : pas encore testé ;
- **décidé** : choix pris, avec ses limites.

---

## 1. Ce qui s'est passé

### 1.1 Chronologie (confirmé, sauf mention)

| Étape | Constat |
|---|---|
| Premier build du commit `a6a3d34` (changement de fond de page) | Digest d'index `sha256:7391ef3d…`, relu dans le registre par le job `read-digest` |
| Dev puis prod déployés sur ce digest | Les deux overlays référencent `7391ef3d…` ; captures : fond bleu clair des deux côtés après promotion |
| PRA complet | Réussi. Les deux nœuds workload ont retéléchargé `7391ef3d…` depuis le registre restauré. |
| Relancement du **workflow `ci`** (exécution #6) depuis l'interface | **Erreur de manipulation :** l'exécution à relancer était celle de `ci-dry-run`. Le workflow `ci` a reconstruit le même commit. |
| Résultat | Le tag `a6a3d34` pointe vers `sha256:f39c5eb1…` (index `application/vnd.oci.image.index.v1+json`, enfants `27fed56e…` pour `linux/amd64` et `b9fa64c1…` pour l'attestation, tous en `HTTP 200`) |
| Ancien index `7391ef3d…` | **`HTTP 404`** dans le registre |
| Dev et prod | Référencent toujours `7391ef3d…`. Ils tournent grâce au cache de containerd, pas grâce au registre. |

### 1.2 Ce qui n'est pas établi

- **Pourquoi deux builds du même commit donnent deux digests.** Pistes : horodatages des fichiers clonés dans l'image, attestation de provenance qui contient des horodatages. Le test prévu pour trancher (workflow `runner-smoke-repro.yaml`, deux clones, quatre builds sans push, avec et sans `SOURCE_DATE_EPOCH`) **n'a pas été exécuté**.
- **Pourquoi l'ancien index a disparu.** Hypothèse : Gitea supprime le manifeste précédent quand un tag est réécrit. Rien dans la documentation consultée ne le décrit. La documentation officielle du registre ne mentionne que le nommage, le push et le pull.
- **Les deux anciens enfants** (`2241fb3d…`, `cf5b3fae…`) sont encore listés comme versions du paquet `2048`. Je les rattache à l'ancien index sans l'avoir vérifié.
- **Le message `'runs-on' key not defined in ci/…`** apparaît dans les journaux de certains jobs, en nommant le job précédent de `needs`. Aucun effet visible, cause inconnue.

---

## 2. Ce que disent les sources

| Sujet | Constat | Source |
|---|---|---|
| Builds non reproductibles par défaut | Horodatages des couches, caches, dépendances non épinglées : deux builds du même Dockerfile donnent presque toujours des empreintes différentes | Articles OneUptime et Mironsoft (2025-2026) |
| `SOURCE_DATE_EPOCH` | Convention pour figer les horodatages de l'index, de la config et des métadonnées de fichiers. Argument de build spécial depuis BuildKit 0.11. | Docker Docs « Reproducible builds with GitHub Actions » ; `moby/buildkit` `docs/build-repro.md` |
| Attestations | Docker ajoute par défaut une attestation de provenance (`mode=min`) avec des horodatages de build | Docker Docs « Build attestations » et « Provenance attestations » |
| Attestation et digest | Un rapport sur Docker Compose décrit une attestation avec horodatages et identifiant d'invocation unique : chaque build produit un nouvel index. Avec le magasin d'images containerd, `provenance: false` serait ignoré, alors que `BUILDX_NO_DEFAULT_ATTESTATIONS=1` fonctionne. | Ticket `docker/compose` n°14111 |
| Tags et digests | Un tag est un alias modifiable, y compris un tag de version. En production, épingler par digest. | Blog Stéphane Robert (OCI) ; OneUptime (signature par digest) |
| Réécrire un tag | D'après un message StackOverflow, le tag se déplace et l'ancienne image reste téléchargeable par son digest. **Ce n'est pas ce qui a été observé dans ce Gitea.** | StackOverflow |
| Harbor | Documente le même principe et propose une politique d'immutabilité des tags par projet | Harbor docs « Tag Immutability Rules » |
| Gitea, registre | Documentation officielle : nommage, push, pull. **Aucune option d'immutabilité des tags trouvée.** Un ticket de 2025 (n°35853) montre que réécrire un tag est un usage réel, avec un bug en 1.25.0 corrigé en 1.25.2. | Docs Gitea « Container Registry » ; ticket `go-gitea/gitea` n°35853 |
| `GITEA_TOKEN` et registre | `GITEA_TOKEN` ne peut pas publier dans le registre de paquets de son dépôt. Il faut un jeton personnel. | Docs Gitea « Compared to GitHub Actions » |
| Sorties de jobs | Syntaxe `outputs` et `needs.<job>.outputs` décrite pour GitHub. Un utilisateur de Gitea l'a fait fonctionner. **Non testé sur cette instance.** | Docs GitHub ; forum Gitea |
| Annulation automatique | Un nouveau push annule les runs en cours du même dépôt, branche et workflow. L'option `concurrency` serait supportée depuis Gitea 1.26 (message de forum). **Non vérifié sur 1.27.0.** | Tickets et forum Gitea |
| `workflow_dispatch` | Supporté depuis Gitea 1.23 d'après un message de forum. **Non testé ici.** | Forum Gitea ; API Gitea |

**Conclusion tirée :** la non-reproductibilité d'un build est un comportement habituel, pas un défaut de ce lab. Ce qui a posé problème n'est pas le build, mais un tag réécrit qui a fait disparaître un digest référencé.

---

## 3. Décision prise : la version simple

**Objectif unique : qu'un digest référencé par un overlay ne disparaisse jamais du registre.**

**Comportement retenu pour le workflow `ci` :**
- **Tag existant :** relire son digest et vérifier qu'il est servi, sans reconstruire.
- **Tag absent :** construire et pousser, puis relever le digest.
- **Avant d'écrire un digest quelque part :** l'index et ses enfants doivent répondre `200`.
- **Ensuite :** écrire l'overlay dev, avec des garde-fous (voir 3.1).
- **Promotion vers prod :** reste manuelle, par un commit distinct.

**Pourquoi un relancement devient inoffensif :** le tag est le commit court, donc le même commit retrouve son tag, qui n'est plus réécrit.

### 3.1 Garde-fous de l'écriture de l'overlay dev (prévus, non écrits)

- ne rien écrire si le digest n'est pas servi ;
- vérifier que le seul fichier modifié est l'overlay dev, parce que le jeton de `ci-bot` pourrait aussi écrire dans l'overlay prod ;
- un digest identique est un simple « inchangé », sans commit ;
- un push refusé déclenche un `pull --rebase` puis un nouvel essai ;
- l'auteur du commit est configuré explicitement.

### 3.2 Contrôle de prévol : digests référencés (décidé, niveau avertissement)

**Principe :** pour chaque overlay, vérifier que le digest référencé est servi par le registre. **Niveau `WARN` : il ne bloque pas le PRA.** Il aurait détecté l'incident du 9 octobre, et il couvre aussi un `docker push` manuel, que la règle du workflow ne couvre pas.

**À faire avant de le coder :** lire `scripts/check-external-deps.sh` pour reprendre son format de résultat, et vérifier si le registre est lisible sans authentification depuis le poste.

### 3.3 Ce qui a été écarté, pour l'instant

- l'option manuelle de reconstruction (par `workflow_dispatch`) avec une raison obligatoire ;
- un tag mobile `dev` qui suit la dernière version ;
- une section de documentation dédiée sur les tags.

**Motif :** cas très particulier, jugé peu probable dans ce lab. Complexité disproportionnée. Une phrase dans la capitalisation suffit : « un relancement ne reconstruit pas ».

---

## 4. Limites acceptées

| Cas | Pourquoi il reste possible |
|---|---|
| Un `docker push` manuel sur un tag existant | La règle est dans le workflow, pas dans le registre. Le jeton `REGISTRY_TOKEN` a les droits d'écriture et de suppression. |
| Un autre workflow de l'organisation `games` | Le secret est disponible pour tous les dépôts de l'organisation |
| Deux exécutions simultanées du même commit | Le test d'existence et le push ne sont pas atomiques |
| Un tag supprimé puis recréé | Le test d'existence ne le détecte pas |

**Qualification :** immutabilité **par convention**, pas garantie. Le risque réel est faible tant qu'une seule personne écrit dans l'organisation.

**Conséquence pour les développeurs :** un tag existant n'est pas reconstruit. Livrer à nouveau sous le même nom n'est pas possible par ce chemin. C'est un compromis assumé.

---

## 5. Points à valider avant ou pendant l'écriture du workflow

1. **Sorties de jobs :** le passage d'un digest d'un job à l'autre. À tester sur un workflow sans secret. Sinon, tout tiendra dans un seul job, mais `docker:cli` n'a pas `bash` alors que `set-overlay-digest.sh` en a besoin.
2. **`concurrency` :** à tester avant de s'y fier. Sans elle, un push rapproché peut couper un run entre la publication de l'image et l'écriture de l'overlay. L'image existerait sans overlay mis à jour, et le run suivant corrigerait.
3. **Filtre `paths-ignore` :** non vérifié.
4. **Contexte `gitea.sha` :** confirmé par le premier run (`HEAD = gitea.sha`).
5. **Dès que la CI commite dans `gitops-lab` :** faire `git pull --ff-only gitea main` dans `~/lab/gitops-lab` avant chaque commit ou PRA, sinon le prévol s'arrête sur la comparaison avec `gitea/main`.

---

## 6. À décider plus tard

- **Reprendre ou non le test de reproductibilité** (`runner-smoke-repro.yaml`), qui dirait si l'image elle-même change entre deux builds ou seulement son attestation.
- **Figer les builds** avec `SOURCE_DATE_EPOCH`, si la reproductibilité devient un objectif. Ce n'est pas nécessaire à un modèle « construire une fois, relire le digest, promouvoir ».
- **Désactiver l'attestation** : à ne pas faire sans test, vu le rapport sur `provenance: false` ignoré avec le magasin containerd.
- **Une vraie garantie d'immutabilité :** politique du registre (non trouvée dans Gitea), jeton de publication séparé du jeton de suppression (portées par catégorie, donc peut-être impossible), ou contrôle a posteriori (le contrôle de prévol de 3.2).
- **Rétention du registre :** aucune version n'a été supprimée. Les enfants orphelins de l'ancien index et le paquet `ci-smoke` ne sont pas nettoyés.

---

## 7. Fil de reprise

**État au moment de la rédaction :**
- L'overlay dev et l'overlay prod référencent `7391ef3d…`, absent du registre. **Correction en attente** : faire pointer dev puis prod vers `f39c5eb1…`, après vérification que l'index, ses deux enfants et le téléchargement par les deux nœuds sont conformes (ce qui est le cas).
- Le workflow `ci` actuel ne contient pas encore les garde-fous.
- Aucun PRA ni nouvelle exécution de `ci` avant la correction des overlays.

**Ordre prévu :**
1. corriger l'overlay dev, puis prod, vers `f39c5eb1…` ;
2. écrire le workflow, partie 1 : capture et vérification du digest, sans écriture dans `gitops-lab` ;
3. écrire le workflow, partie 2 : écriture de l'overlay dev ;
4. ajouter le contrôle de prévol (3.2) ;
5. intégrer cette note dans le document de la v1.3.3.

---

## Sources de référence

- Docker Docs : « Reproducible builds with GitHub Actions », « Build attestations », « Provenance attestations ».
- `moby/buildkit` : `docs/build-repro.md`.
- Ticket `docker/compose` n°14111 (provenance et magasin containerd).
- Docs Gitea : « Container Registry », « Compared to GitHub Actions », API « Create a workflow dispatch event ».
- Ticket `go-gitea/gitea` n°35853 (réécriture des tags de paquets).
- Forum Gitea : passage de variables entre jobs, annulation automatique sur push, entrées utilisateur.
- Harbor docs : « Tag Immutability Rules ».
- StackOverflow : « What happens when you push a new image with same old tag? ».
- Articles OneUptime et Mironsoft sur les builds reproductibles et la signature par digest.

Elles décrivent les outils mais ne prouvent pas l'état du lab.
