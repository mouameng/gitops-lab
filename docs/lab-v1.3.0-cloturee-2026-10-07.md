## GitOps Lab — Capitalisation v1.3.0 : Gitea source de vérité GitOps, PRA rejoué deux fois

**Statut : v1.3.0 clôturée le 7 octobre 2026.** Le dépôt GitOps (manifests Argo CD, Applications, projets) n'est plus lu depuis GitHub mais depuis le dépôt `gitea_admin/gitops-lab` hébergé dans Gitea, à l'intérieur du cluster management. Le bootstrap restaure puis installe Gitea directement, avant toute autre étape dépendant du dépôt, et publie ses propres commits de PRA dans Gitea sans jamais passer par GitHub. Le PRA multicluster a été rejoué **deux fois** avec le même résultat, y compris la préservation du dépôt GitOps et de l'image 2048 à travers un cycle restauration → nouvelle sauvegarde.

**Révision de référence :** le tag v1.3.0 désigne la révision qui **ajoute ce document** dans Gitea ; son parent est le dernier commit `chore(pra): renew workload registrations` du second PRA. Le hash du commit de clôture n'est pas inscrit ici : utiliser `git rev-parse 'v1.3.0^{commit}'` dans le dépôt Gitea.

**Remplace :** `gitops-lab-capitalisation-v1.2.3-cloturee-2026-10-07.md`. Le contenu utile de la v1.2.3 (2048 en ligne, registre OCI, PRA validé deux fois) reste acquis et n'est pas repris en détail ici ; seul un rappel bref figure en section 3. Les versions plus anciennes restent dans `docs/`.

**Périmètre :** lab personnel Kind/GitOps (management + workloads dev/prod), bascule de la source de vérité GitOps de GitHub vers Gitea, scripts d'installation directe et de publication, migration des références de dépôt, PRA rejoué deux fois.

**Convention de lecture :**
- **confirmé** : sortie ou capture rapportée dans les échanges ;
- **hypothèse** : explication cohérente avec les observations, non prouvée ;
- **à valider** : pas encore démontré.

Une commande citée sans résultat ne vaut pas preuve de son exécution.

### 1. Synthèse

Après la v1.2.3 (2048 en ligne, registre OCI de Gitea, PRA validé deux fois), l'objectif était de **ne plus dépendre de GitHub** pour héberger la source de vérité GitOps du lab, tout en conservant un PRA fiable et rejouable. Il s'agissait de résoudre le problème classique de l'œuf et de la poule : Argo CD lit aujourd'hui son dépôt de manifests depuis Gitea, alors que Gitea lui-même est déployé par Argo CD.

**Décisions :**
- **Gitea est installé deux fois selon le contexte.** En fonctionnement normal, Argo CD gère Gitea comme n'importe quelle Application (chart officiel, values versionnées). Au PRA, sur un cluster neuf, Gitea est **restauré puis installé directement** (`helm template` + `kubectl apply`, avec exactement la même source — chart, version, values — que l'Application Argo CD), avant que quoi que ce soit ne dépende du dépôt. Argo CD reprend ensuite la main à la première synchronisation, sans recréer les objets.
- **Le bootstrap ne pousse plus jamais vers GitHub.** Le commit de renouvellement des enregistrements de workloads (SealedSecrets des clusters dev/prod) est désormais publié dans Gitea via un script dédié, par `kubectl port-forward`, avant même que `gitea.local` soit joignable (Traefik n'arrive qu'avec la Root App).
- **URL interne, sans TLS.** Argo CD lit Gitea par l'URL de service interne du cluster (`http://gitea-http.gitea.svc.cluster.local:3000/...`), ce qui évite toute dépendance à la CA du lab pour ce chemin précis.
- **Dépôt en SHA-1, et non SHA-256.** Un premier essai en SHA-256 a été corrigé : ce format casse l'action `checkout` des workflows compatibles GitHub Actions et n'est pas accepté par GitHub, ce qui aurait bloqué tout push-mirror futur.
- **GitHub reste en place comme filet de sécurité**, volontairement figé sur le dernier commit de la v1.2.3 pendant toute la bascule, le temps de valider deux PRA complets.

**État au 7 octobre 2026 :**
- Dépôt `gitea_admin/gitops-lab` créé dans Gitea (SHA-1, public), peuplé avec `main` et les 7 tags historiques, identiques à GitHub.
- 17 références de dépôt (15 `repoURL`, 2 `sourceRepos`) migrées de l'URL GitHub vers l'URL interne de Gitea.
- Deux scripts ajoutés : `scripts/install-gitea-direct.sh` (installation directe de Gitea) et `scripts/gitea-publish.sh` (publication vers Gitea par port-forward, sans jamais forcer).
- Bootstrap patché : restauration puis installation directe de Gitea déplacées avant la publication du commit de PRA ; garde de prévol `--render-check` ajoutée avant toute destruction.
- **PRA v1.3.0 rejoué deux fois :** même CA, certificats réémis, 25 Applications Synced/Healthy, Gitea adopté par Argo CD sans recréation (tracking-id présent, un seul ReplicaSet), 16 fichiers packages, image 2048 par digest, jeton de publication valide après restauration de `gitea.db`, GitHub resté inchangé.
- **Reporté (points ouverts, section 8) :** mode sinistre du prévol (suppose un Gitea vivant), push mirror vers GitHub, branches `pra/*` absentes de Gitea, documentation GitHub non mise à jour, CI (Gitea Actions).

### 2. Architecture de référence

#### 2.1 Chaîne de lecture du dépôt GitOps

Avant la v1.3.0 :
```
Argo CD (Root App, Applications, projets) --- lit ---> GitHub (mouameng/gitops-lab)
Gitea --- déployé par ---> Argo CD depuis GitHub
```

Depuis la v1.3.0 :
```
Argo CD (Root App, Applications, projets) --- lit ---> Gitea (URL interne, HTTP, sans TLS)
   http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/gitops-lab.git

Gitea --- restauré puis installé directement par le bootstrap ---> repris par Argo CD à la 1ère synchro
   (plus aucune dépendance à GitHub pour démarrer)

GitHub --- copie figée, filet de sécurité ---> à synchroniser plus tard (push mirror, hors périmètre v1.3.0)
```

#### 2.2 Ordre du bootstrap (nouveau)

L'ordre a changé sur un point précis : Gitea doit exister et être joignable **avant** que le commit de renouvellement des enregistrements ne soit publié, et bien avant que `cluster-registration` ou la Root App ne soient appliquées.

```
1. Garde registre (accès des nœuds workload), sauvegarde de clé Sealed Secrets validée
2. Prévol : main local vs gitea/main (plus GitHub) ; gitea-publish.sh --check ;
   install-gitea-direct.sh --render-check (outils, source, rendu — sans accès cluster)
3. Sauvegarde fraîche de Gitea, jeu figé pour le PRA
4. Destruction puis recréation des 3 clusters Kind
5. Accès des nœuds workload au registre Gitea (inchangé, v1.2.3)
6. Argo CD, CA, ClusterIssuer, Sealed Secrets (inchangé, v1.2.2/v1.2.3)
7. [NOUVEAU] Restauration des données de Gitea (PVC, Secret admin) — inchangé dans son contenu,
   déplacé plus tôt dans la séquence
8. [NOUVEAU] Installation directe de Gitea (helm template + kubectl apply, même source que
   l'Application Argo CD) ; préflight puis installation
9. Préparation et commit des enregistrements de workloads (inchangé)
10. [NOUVEAU] Publication du commit vers Gitea par gitea-publish.sh (port-forward, sans --force) ;
    remplace l'ancien push vers GitHub
11. cluster-registration (lit désormais Gitea), attente Synced sur le commit du PRA
12. Root App (lit désormais Gitea)
13. Synchronisation manuelle de gitea et gitea-external (adoption par Argo CD, inchangé dans
    son principe depuis la v1.2.2)
```

#### 2.3 Applications et projets Argo CD

Aucune Application n'a été ajoutée ou retirée. Seule la valeur de `repoURL` change, pour 14 Applications et la seconde source de `gitea.yaml`, plus la Root App et les deux projets (`applications-project`, `infrastructure-project`). Les dépôts de charts externes (jetstack, traefik, metallb, ingress-nginx, metrics-server, sealed-secrets, `dl.gitea.io`) ne changent pas et restent des dépendances externes du PRA.

`infrastructure-project.yaml` est appliqué directement par le bootstrap (ligne ~589, avant Sealed Secrets), ce qui garantit que son `sourceRepos` contient déjà l'URL de Gitea avant que `cluster-registration` — membre de ce projet — ne soit appliquée à son tour.

### 3. Rappel v1.2.3 (acquis, non repris en détail)

2048 en ligne sur dev et prod, image stockée dans le registre OCI de Gitea et référencée par digest (`sha256:c76fe9312b4e7dc20bd08117023d337c604274c4bc613b6690fc70200e892b7d`), accès des nœuds workload au registre posé par un patch containerd et un script rejouable, CA privée (v1.2.2) inchangée. Voir `gitops-lab-capitalisation-v1.2.3-cloturee-2026-10-07.md` pour le détail.

### 4. Travaux réalisés et preuves

#### 4.1 Création du dépôt dans Gitea et erreur de format corrigée

- Premier essai : dépôt `gitea_admin/gitops-lab` créé en **SHA-256**. Le push a échoué : `fatal: the receiving end does not support this repository's hash algorithm`, un dépôt local en SHA-1 ne pouvant pousser vers un dépôt distant SHA-256.
- **Risque identifié avant correction :** un dépôt SHA-256 aurait aussi cassé l'action `checkout` des workflows compatibles GitHub Actions dans Gitea Actions (prévu pour la v1.3.1), et GitHub lui-même n'acceptait pas ce format au moment de la recherche — ce qui aurait bloqué tout push-mirror futur.
- **Correction :** dépôt supprimé puis recréé en **SHA-1**, public, branche par défaut `main`, sans README ni `.gitignore` ni licence.
- **Jeton dédié :** `git-push-wsl`, permission dépôt lecture/écriture uniquement, créé dans l'interface de `gitea_admin`. Jamais collé dans le chat ; stocké dans `~/.config/gitops-lab/gitea-git-token` (répertoire 700, fichier 600).
- **Publication initiale :** `git push gitea main` puis `git push gitea --tags` (765 objets pour `main`, 7 tags). Les trois branches de travail `pra/*` n'ont volontairement pas été poussées à ce stade (hors périmètre de la v1.3.0).
- **Contrôles :** `diff` entre `git ls-remote origin` et `git ls-remote gitea` sur `main` et les tags → identiques. Lecture anonyme via `https://gitea.local/...` → 200. Lecture par l'URL interne depuis un `exec` dans `argocd-repo-server` → même commit.

#### 4.2 Scripts ajoutés

**`scripts/install-gitea-direct.sh`** — installe Gitea par `helm template` (dépôt de charts, version, nom de release et fichier de values lus **exclusivement** dans `argocd/applications/gitea.yaml`, source unique) puis `kubectl apply`, sans jamais appeler `helm install` (ce qui aurait créé un Secret de release Helm non suivi par Argo CD).
- Contrôle que le rendu produit exactement 7 objets (1 Deployment, 1 PVC, 2 Services, 3 Secrets), sans Secret administrateur ni Namespace.
- Garde-fous avant toute écriture : namespace présent, `gitea-admin-secret` présent, PVC lié et de spec conforme (classe de stockage, taille, mode d'accès) à ce qu'attend le rendu, aucun Deployment ni pod déjà présents.
- Trois modes : `--render-check` (outils, source et rendu uniquement, **aucun accès au cluster**, utilisé en prévol avant destruction), `--preflight` (dry-run serveur, défaut), `--install` (applique, attend le rollout et le PVC lié).
- **Déterminisme vérifié :** deux rendus `helm template` consécutifs produisent un hash identique ; les clés des 3 Secrets rendus correspondent exactement aux clés des Secrets déjà en place sur le cluster de référence (aucune valeur générée aléatoirement qui aurait pu être écrasée).

**`scripts/gitea-publish.sh`** — publie `main` vers Gitea par `kubectl port-forward` sur `deploy/gitea` (port local 13000), car `gitea.local` n'est pas encore joignable à ce stade du PRA (Traefik arrive avec la Root App).
- Jeton lu dans le fichier 600 ci-dessus, transmis à Git via `GIT_ASKPASS` (jamais en argument de commande, jamais affiché).
- Vérifie que `main` distant est un **ancêtre** du commit à publier (avance rapide) avant toute écriture ; **ne force jamais** (`--force` absent du script).
- Deux modes : `--check` (dry-run, utilisé en prévol), `--push <sha>` (publication, relit `main` distant ensuite pour confirmer).

#### 4.3 Migration des références de dépôt (17 occurrences)

Script `migrate-repourl.py` (outil local, non suivi par Git, conservé dans `~/lab/tools/`) : remplace `https://github.com/mouameng/gitops-lab.git` par `http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/gitops-lab.git` dans 15 `repoURL` (Root App, 14 Applications, seconde source de `gitea.yaml`) et 2 `sourceRepos` (les deux projets Argo CD). Refuse d'écrire si le relevé ne correspond pas exactement à 17 occurrences sous la forme attendue (dry-run par défaut, aucune sauvegarde `.before-*` nécessaire : fichiers suivis par Git, retour arrière par `git checkout --`).

Trois fichiers hors périmètre continuent de citer GitHub et n'ont pas été modifiés : `README-bootstrap.md`, `docs/bootstrap-gitops-autonome.md`, et le document de capitalisation v1.2.2 (historique, volontairement inchangé).

#### 4.4 Patch du bootstrap (deux passes, ancres uniques)

Deux scripts Python locaux (`patch-bootstrap-gitea.py`, `patch-bootstrap-guard.py`), chacun en dry-run par défaut, avec sauvegarde `.before-*` à l'application, et refus d'écrire si une ancre est trouvée 0 ou plus d'une fois dans le fichier cible.

- **Premier patch :** déplace le bloc de restauration de Gitea avant le commit des enregistrements ; y ajoute l'appel à `install-gitea-direct.sh` (préflight puis installation) ; remplace le prévol `origin` par `gitea` et le push `git push origin` par `gitea-publish.sh --push` ; supprime l'ancienne vérification du push distant (déléguée à `gitea-publish.sh`).
- **Second patch :** ajoute l'appel `install-gitea-direct.sh --render-check` dans le prévol réel (avant le menu de destruction), juste après `gitea-publish.sh --check`. Reproduit la leçon de la v1.2.3 sur la garde de prévol (section 4.4 du document précédent) : un script ou un outil manquant doit être détecté **avant** la destruction, pas après la recréation des clusters.
- Les deux patchs ont été testés sur des copies factices avant d'être appliqués au fichier réel (ancre absente, ancre dupliquée, ré-application refusée).
- **Résultat sur `scripts/bootstrap-platform.sh` :** 37 lignes modifiées (23 ajouts, 13 suppressions au premier patch ; 1 ligne ajoutée au second), `bash -n` et `git diff --check` conformes à chaque étape.

#### 4.5 Commit, fusion et premier push réel

- Travail effectué sur une branche (`feat/v1.3.0-gitea-source`), pour ne pas perturber le cluster en cours d'exécution (dont la Root App lisait encore GitHub).
- Commit unique `ffa47a1` : 20 fichiers, 283 insertions, 30 suppressions (17 références migrées + bootstrap patché + 2 nouveaux scripts).
- Fusion en avance rapide dans `main` local. GitHub (`origin/main`) volontairement **non modifié** : resté sur `7e8f856` (tag v1.2.3) pendant toute la validation.
- **Premier push réel vers Gitea seul** (`gitea-publish.sh --push ffa47a1...`) : preuve que le jeton a bien les droits d'écriture (un dry-run précédent n'avait rien eu à pousser et ne le prouvait pas). Avance rapide confirmée (`7e8f856..ffa47a1`), relecture de `main` distant conforme.
- Contrôle croisé : lecture du nouveau commit par le `repo-server` d'Argo CD via l'URL interne → conforme, avant même la bascule des `repoURL`.

#### 4.6 Sauvegarde manuelle de contrôle avant le premier PRA

Les jeux de sauvegarde existants avaient tous été pris **avant** la création du dépôt `gitops-lab` dans Gitea ; les restaurer aurait laissé la Root App sans dépôt à lire. Une sauvegarde manuelle (`backup-gitea.sh --backup`) a été prise et contrôlée avant tout PRA : jeu `20261007-220927`, contenant `gitops-lab` (HEAD présent dans l'archive) et les 16 fichiers packages attendus. `--validate` conforme.

#### 4.7 PRA v1.3.0 n°1

**Préparation :** dépôt sur `ffa47a1`, prévol réel conforme (toutes les gardes, y compris les deux nouvelles). **Exécution :** `./scripts/bootstrap-platform.sh`, choix 2, jeu `[SELECT] 20261007-220927` (vérifié différent de l'ancien jeu sans `gitops-lab`).

<table>
<tr><th>Contrôle</th><th>Avant</th><th>Après</th><th>Verdict</th></tr>
<tr><td>Empreinte de la CA</td><td>AD:AF:…:A3:A1:92</td><td>AD:AF:…:A3:A1:92</td><td>✅ identique</td></tr>
<tr><td>Certificat gitea-local</td><td>8B:A0:…:7E:46</td><td>E0:D4:…:05:41, émis par la CA</td><td>✅ réémis</td></tr>
<tr><td>Applications Argo CD</td><td>25 Synced/Healthy</td><td>25 Synced/Healthy</td><td>✅</td></tr>
<tr><td>repoURL du dépôt GitOps</td><td>GitHub (15 occurrences)</td><td>15 sur l'URL interne Gitea, 0 GitHub</td><td>✅</td></tr>
<tr><td>Suivi Argo CD du Deployment gitea</td><td>absent (installation directe)</td><td>tracking-id présent, 1 seul ReplicaSet, 0 redémarrage</td><td>✅ adopté, non recréé</td></tr>
<tr><td>Fichiers packages</td><td>16</td><td>16</td><td>✅</td></tr>
<tr><td>gitops-lab (main + 7 tags)</td><td>ffa47a1</td><td>458b70d (enfant de ffa47a1), tags inchangés</td><td>✅</td></tr>
<tr><td>Dépôts 2048 / gitea-test</td><td>8c32cea / 7748811</td><td>identiques</td><td>✅</td></tr>
<tr><td>Pods 2048 (dev/prod)</td><td>Running</td><td>Running, digest sha256:c76fe93… confirmé</td><td>✅</td></tr>
<tr><td>Jeton git-push-wsl</td><td>valide</td><td>valide, push du bootstrap réussi</td><td>✅</td></tr>
<tr><td>GitHub main</td><td>7e8f856f</td><td>7e8f856f</td><td>✅ inchangé</td></tr>
<tr><td>Code retour bootstrap</td><td>—</td><td>0, aucun [STOP] dans le journal</td><td>✅</td></tr>
</table>

Le commit `458b70d` (« renew workload registrations ») a été poussé par le bootstrap directement dans Gitea via `gitea-publish.sh`, sans toucher à GitHub ni aux tags.

#### 4.8 PRA v1.3.0 n°2 (rejeu à l'identique)

**Préparation :** dépôt sur `458b70d` (`main` local et `gitea/main` identiques). **Exécution :** même commande, choix 2, nouvelle sauvegarde fraîche prise sur un Gitea **déjà restauré** par le premier PRA — jeu `[SELECT] 20261007-222723`.

<table>
<tr><th>Contrôle</th><th>PRA n°1</th><th>PRA n°2</th><th>Verdict</th></tr>
<tr><td>Empreinte CA</td><td>AD:AF:…:A3:A1:92</td><td>AD:AF:…:A3:A1:92</td><td>✅ identique</td></tr>
<tr><td>Certificat gitea-local</td><td>E0:D4:…:05:41</td><td>9A:13:…:60:46, émis par la CA</td><td>✅ réémis</td></tr>
<tr><td>Applications Argo CD</td><td>25 Synced/Healthy</td><td>25 Synced/Healthy</td><td>✅</td></tr>
<tr><td>repoURL GitOps</td><td>15 sur Gitea, 0 GitHub</td><td>15 sur Gitea, 0 GitHub</td><td>✅</td></tr>
<tr><td>Suivi Argo CD du Deployment</td><td>tracking-id présent</td><td>tracking-id présent</td><td>✅ adopté, non recréé</td></tr>
<tr><td>Fichiers packages</td><td>16</td><td>16</td><td>✅</td></tr>
<tr><td>gitops-lab main</td><td>458b70d</td><td>289a6f7 (enfant de 458b70d)</td><td>✅ progression cohérente</td></tr>
<tr><td>Tags gitops-lab</td><td>7, inchangés</td><td>7, inchangés</td><td>✅</td></tr>
<tr><td>2048 / gitea-test</td><td>8c32cea / 7748811</td><td>8c32cea / 7748811</td><td>✅</td></tr>
<tr><td>Pods 2048</td><td>Running</td><td>Running, 0 redémarrage</td><td>✅</td></tr>
<tr><td>Jeton git-push-wsl</td><td>valide, push réussi</td><td>valide, push réussi</td><td>✅</td></tr>
<tr><td>GitHub main</td><td>7e8f856f</td><td>7e8f856f</td><td>✅ toujours inchangé</td></tr>
<tr><td>Code retour bootstrap</td><td>0</td><td>0</td><td>✅</td></tr>
</table>

**Preuve supplémentaire, spécifique à la v1.3.0 :** la sauvegarde prise pendant ce second PRA (jeu `20261007-222723`, issue d'un Gitea qui venait d'être restauré puis réinstallé) a été contrôlée après coup — `gitops-lab` présent (HEAD dans l'archive) et 16 fichiers packages. Le dépôt GitOps et l'image 2048 survivent donc à un cycle complet *restauration → réinstallation → nouvelle sauvegarde*, et pas seulement à une sauvegarde initiale prise avant toute destruction.

#### 4.9 Commentaire sur `generation=2` du Deployment gitea

Observation faite aux deux PRA : `kubectl get deploy gitea` affiche `generation=2` après l'installation directe puis l'adoption par Argo CD, alors que `rollout history` ne montre qu'une seule révision (`REVISION 1`), un seul ReplicaSet actif et 0 redémarrage de pod. **Hypothèse non prouvée :** la génération s'incrémente quand Argo CD modifie les annotations de l'objet (ajout du `tracking-id`) sans toucher au modèle de pod, ce qui n'entraîne pas de nouveau déploiement. Sans conséquence observée sur les deux PRA.

### 5. Historique Git gitops-lab (dépôt Gitea)

<table>
<tr><th>Commit</th><th>Contenu</th><th>Remarque</th></tr>
<tr><td>7e8f856</td><td>docs: add v1.2.3 capitalisation</td><td>porte le tag v1.2.3 ; point de départ de la v1.3.0 ; identique à GitHub pendant toute la bascule</td></tr>
<tr><td>ffa47a1</td><td>feat(v1.3.0): Gitea comme source de vérité GitOps</td><td>20 fichiers, 283 insertions, 30 suppressions ; fusionné en avance rapide depuis feat/v1.3.0-gitea-source ; premier commit publié vers Gitea seul</td></tr>
<tr><td>458b70d</td><td>chore(pra): renew workload registrations</td><td>poussé par le bootstrap via gitea-publish.sh (PRA n°1)</td></tr>
<tr><td>289a6f7</td><td>chore(pra): renew workload registrations</td><td>poussé par le bootstrap via gitea-publish.sh (PRA n°2)</td></tr>
<tr><td><em>(commit de clôture)</em></td><td>docs: add v1.3.0 capitalisation</td><td>porte le tag v1.3.0 ; ajoute uniquement ce document, dans Gitea</td></tr>
</table>

**Branches locales non portées dans Gitea :** `pra/multicluster-publish`, `pra/multicluster-recovery`, `pra/registration-isolated` existent sur GitHub et dans le clone local, mais n'ont pas été poussées vers Gitea (hors périmètre v1.3.0 ; voir points ouverts).

### 6. État de validation v1.3.0 (bilan)

<table>
<tr><th>Critère</th><th>État</th><th>Preuve ou limite</th></tr>
<tr><td>Gitea source de vérité GitOps (Root App, Applications, projets)</td><td>✅ Atteint</td><td>17 références migrées, 0 repoURL GitHub restant</td></tr>
<tr><td>Dépôt restauré puis installé directement avant toute dépendance au dépôt</td><td>✅ Atteint</td><td>install-gitea-direct.sh, source unique = Application Argo CD</td></tr>
<tr><td>Argo CD adopte Gitea sans le recréer</td><td>✅ Atteint</td><td>tracking-id présent, 1 ReplicaSet, 0 redémarrage, aux deux PRA</td></tr>
<tr><td>Publication du bootstrap sans dépendre de GitHub</td><td>✅ Atteint</td><td>gitea-publish.sh, port-forward, jamais --force</td></tr>
<tr><td>Garde de prévol avant toute destruction (render-check)</td><td>✅ Atteint</td><td>ajoutée dans le prévol réel, testée avant PRA</td></tr>
<tr><td>Jeton de publication opérationnel après restauration de gitea.db</td><td>✅ Atteint</td><td>push du bootstrap réussi aux deux PRA</td></tr>
<tr><td>PRA multicluster rejoué deux fois</td><td>✅ Atteint</td><td>sections 4.7 et 4.8</td></tr>
<tr><td>Image 2048 et dépôt GitOps préservés sur un cycle restauration → nouvelle sauvegarde</td><td>✅ Atteint</td><td>jeu 20261007-222723 contrôlé après coup</td></tr>
<tr><td>GitHub resté inchangé pendant toute la bascule</td><td>✅ Atteint</td><td>7e8f856 aux deux relevés avant/après</td></tr>
<tr><td>Aucun secret affiché ni commité</td><td>✅ Atteint</td><td>jeton en fichier 600, GIT_ASKPASS, umask 077</td></tr>
<tr><td>Mode sinistre du prévol (Gitea indisponible)</td><td>Non fait</td><td>suppose aujourd'hui un Gitea vivant</td></tr>
<tr><td>Push mirror Gitea → GitHub</td><td>Non fait</td><td>GitHub volontairement figé pendant la validation</td></tr>
<tr><td>Branches pra/* portées dans Gitea</td><td>Non fait</td><td>absentes de Gitea à ce jour</td></tr>
<tr><td>Documentation (README, docs/bootstrap-gitops-autonome.md)</td><td>Non fait</td><td>citent encore GitHub</td></tr>
<tr><td>Tag v1.3.0</td><td>À poser sur le commit de clôture</td><td>section 4.12 (à venir)</td></tr>
</table>

### 7. Points de vigilance et savoir-faire

**Dépôt Git et formats**
- Toujours vérifier le format d'objet (SHA-1/SHA-256) d'un dépôt Gitea nouvellement créé avant le premier push : l'erreur n'apparaît qu'au push, jamais à la création.
- Un push `--all` depuis un clone non nu pousserait aussi les références `refs/remotes/origin/*` : préférer `push <remote> main` puis `push <remote> --tags` pour un contrôle explicite des branches envoyées.

**Installation directe vs gestion par Argo CD**
- Toujours faire rendre les manifests avec `helm template` (jamais `helm install`) quand l'objectif est une reprise ultérieure par Argo CD : `helm install` crée un Secret de release que Argo CD ne connaît pas.
- Vérifier le déterminisme du rendu (deux rendus consécutifs, comparaison de hash) et comparer les clés des Secrets rendus à celles déjà en place, avant de autoriser un `apply` qui pourrait silencieusement remplacer des valeurs générées.
- Une installation directe doit refuser de s'exécuter si l'objet existe déjà (garde symétrique à celle de la restauration, qui refuse elle aussi si l'objet existe déjà) : les deux scripts se protègent mutuellement contre un mauvais ordre d'appel.

**Publication Git sans dépendance au nom d'hôte final**
- Avant que l'Ingress ne soit en service, un `kubectl port-forward` direct vers le Deployment permet de publier un commit sans attendre le certificat ni le nom DNS.
- Ne jamais transmettre un jeton en argument de ligne de commande : utiliser `GIT_ASKPASS` avec un script temporaire, supprimé en fin d'exécution.
- Une publication automatisée ne doit **jamais** avoir de mode `--force` : vérifier l'avance rapide (`merge-base --is-ancestor`) avant toute écriture, et s'arrêter sinon.

**Patch de fichiers par ancre unique**
- Toujours exiger qu'une ancre textuelle soit trouvée exactement une fois avant d'écrire quoi que ce soit ; refuser 0 occurrence (fichier différent de ce qui est attendu) autant que 2+ occurrences (ambiguïté).
- Tester le patch sur une copie factice reconstituée à partir des lignes relevées, avant de l'appliquer au fichier réel — cela a permis de détecter un faux pas de raisonnement (confusion entre deux empreintes de fichiers livrés) avant qu'il n'affecte le dépôt.
- Toujours produire un dry-run par défaut, une sauvegarde `.before-*` à l'application, et valider `bash -n` plus `git diff --check` après écriture.

**Transfert de fichiers entre l'assistant et le poste de travail**
- Un fichier déjà téléchargé sous le même nom peut être re-servi par le cache du navigateur ou du système de fichiers ; en cas de doute sur le contenu reçu, comparer une empreinte (`sha256sum`) avant tout usage, et renommer le fichier de sortie à chaque nouvelle version pour éviter la confusion.

**Gardes de prévol**
- Toute nouvelle dépendance introduite dans le bootstrap (ici : Gitea vivant pour le push et pour le rendu du chart) doit avoir sa garde de prévol testée **avant** la destruction réelle, pas seulement en théorie : reproduit la leçon de la v1.2.3 sur les gardes qui ne protègent pas le chemin réel.

### 8. Feuille de route et points ouverts

**Points ouverts**
- **Mode sinistre du prévol :** `gitea-publish.sh --check` et la comparaison `main` local / `gitea/main` supposent aujourd'hui un Gitea vivant et joignable. Dans un sinistre réel (Gitea perdu, pas seulement les clusters workload), le prévol s'arrêterait. Piste non essayée : un mode qui compare à une copie GitHub (future mirror) et saute ce contrôle.
- **Branches `pra/*` absentes de Gitea :** à pousser avant toute configuration d'un push mirror, pour éviter leur perte côté GitHub si le mirror force la synchronisation.
- **Push mirror Gitea → GitHub :** non configuré. Nécessite un jeton GitHub dédié (droits `public_repo`, éventuellement `workflow`), à créer seulement après la clôture de la v1.3.0 — GitHub est aujourd'hui volontairement figé sur la v1.2.3 et ne doit pas être écrasé avant que la bascule soit définitivement actée.
- **Documentation :** `README-bootstrap.md` et `docs/bootstrap-gitops-autonome.md` citent encore GitHub comme dépôt de référence ; à mettre à jour.
- **`--plan` du bootstrap :** le bloc de prévisualisation affiche encore l'ancien ordre des étapes ; cosmétique, sans impact fonctionnel constaté.
- **Dépendances externes du PRA, inchangées :** GitHub (charts Helm de base), `dl.gitea.io` (chart Gitea). Une indisponibilité de l'un ou l'autre bloquerait un PRA, comme avant la v1.3.0.
- **Image de base nginx (héritage v1.2.2/v1.2.3) :** toujours non vérifiée comme épinglée par digest dans le Dockerfile de 2048.

**Étape suivante : v1.3.1 — CI Gitea Actions.** Pistes validées en amont de ce document, rien d'installé à ce jour :
- runner hébergé dans le cluster management (option retenue), avec décision à prendre entre Docker-in-Docker privilégié (StatefulSet, chemin documenté) et DinD rootless (exposition réduite, limites réseau/stockage) ;
- test de faisabilité en premier : un DinD peut-il tourner dans un nœud Kind du management, lui-même conteneur Docker ;
- `GITEA_TOKEN` ne peut pas publier dans le registre de paquets de son propre dépôt : un jeton de publication dédié reste nécessaire pour la CI, distinct de `git-push-wsl` ;
- objectif v1.3.1 : commit → build → push de l'image → mise à jour du digest dans l'overlay **dev** uniquement ; la promotion vers prod reste un jalon séparé (v1.3.2), non traité ici.

### 9. Dépendances et risques

- **Gitea est désormais sur le chemin de démarrage de toute la plateforme**, et plus seulement sur celui de l'image 2048 : une restauration de Gitea qui échouerait bloquerait Argo CD lui-même, et pas seulement un jeu applicatif. Le filet de sécurité GitHub (copie figée, non automatisée) reste la seule alternative tant que le push mirror n'est pas en place.
- **Le prévol et la publication du bootstrap dépendent tous deux d'un Gitea vivant avant toute destruction.** C'est cohérent avec le fonctionnement d'un PRA planifié (la sauvegarde est prise juste avant), mais ne couvre pas un sinistre où Gitea serait déjà perdu au moment de relancer le bootstrap.
- **Jeton `git-push-wsl` :** stocké en clair dans un fichier 600 local, hors du dépôt ; sa perte oblige à en recréer un dans l'interface de Gitea (l'ancien ne peut pas être réaffiché).
- **Dépendances externes du PRA, inchangées depuis la v1.2.3 :** GitHub pour les charts Helm de base, `dl.gitea.io` pour le chart Gitea lui-même — ce dernier étant désormais utilisé deux fois par PRA (installation directe puis reprise par Argo CD), avec la même version et les mêmes values dans les deux cas.
- **Limite inotify :** toujours 512 au prévol, inchangée depuis la v1.2.3 ; éviter de créer un cluster Kind supplémentaire en dehors du PRA.

### 10. Critères de clôture de v1.3.0

<table>
<tr><th>Critère</th><th>État</th></tr>
<tr><td>Gitea source de vérité GitOps (Root App, Applications, projets)</td><td>✅ Atteint</td></tr>
<tr><td>Restauration puis installation directe de Gitea avant toute dépendance au dépôt</td><td>✅ Atteint</td></tr>
<tr><td>Argo CD adopte Gitea sans le recréer, aux deux PRA</td><td>✅ Atteint</td></tr>
<tr><td>Publication des commits de PRA sans dépendance à GitHub, jamais en force</td><td>✅ Atteint</td></tr>
<tr><td>Garde de prévol testée avant toute destruction réelle</td><td>✅ Atteint</td></tr>
<tr><td>PRA rejoué deux fois : CA identique, certificats réémis, 25 Applications Healthy</td><td>✅ Atteint</td></tr>
<tr><td>Dépôt GitOps et image 2048 préservés sur un cycle restauration → nouvelle sauvegarde</td><td>✅ Atteint</td></tr>
<tr><td>GitHub resté inchangé pendant toute la validation</td><td>✅ Atteint</td></tr>
<tr><td>Aucun secret dans Git ni dans ce document</td><td>✅ Atteint</td></tr>
<tr><td>Tag v1.3.0 posé sur la révision qui contient ce document, dans Gitea</td><td>À faire (voir 4.12, à rédiger à la clôture effective)</td></tr>
</table>

**Version clôturée.** Point de reprise : v1.3.1, choix de l'architecture du runner CI (DinD privilégié vs rootless, test de faisabilité dans un nœud Kind du management en premier), en gardant en tête les points ouverts de la section 8.

### Sources de référence

- Capitalisations v1.2.0 à v1.2.3.
- Preuves v1.3.0 : sorties de commandes, journaux de bootstrap et relevés avant/après des deux PRA du 7 octobre 2026 (`~/.local/share/gitops-lab/pra/`, `~/.local/share/gitops-lab/logs/`).
- Documentation officielle consultée pendant la conception : Gitea (installation Kubernetes du runner, comparaison avec GitHub Actions, permissions `GITEA_TOKEN`, mirroring de dépôt), Argo CD (dépôts privés, certificats de confiance personnalisés), retours d'expérience communautaires sur Gitea Actions vs Woodpecker CI et sur les builds d'images sans démon Docker (Kaniko, BuildKit rootless). Elle décrit les outils mais ne prouve pas l'état du lab.
